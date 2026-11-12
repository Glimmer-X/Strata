import Darwin
import Foundation

/// Walks one volume with getattrlistbulk(2): one system call returns the names and attributes
/// of many directory entries at once, so there is no per-file stat. Directories are handed
/// out to a pool of threads from a shared stack.
///
/// Sizes are allocated bytes. A hard-linked inode is counted where it is met first, and so
/// is a group of APFS clones; later members count as zero. Mounted volumes and folders that
/// exist only in iCloud are not entered.
public final class VolumeScanner: @unchecked Sendable {
    /// What the scan keeps in memory besides the totals.
    public enum Retention: Sendable {
        case none
        /// One record per entry.
        case everything
        /// One record per folder and per file of at least `smallFileBytes`; the smaller files
        /// of a folder are summed into a single record.
        case aggregated(smallFileBytes: UInt64)
    }

    public struct Options: Sendable {
        public var threads = 8
        /// Fetch clone ids so each group of clones is counted once. Cheap.
        public var cloneInfo = true
        /// Fetch the private size of every file. Expensive (about half again the scan time).
        public var privateSize = false
        public var retention: Retention = .none
        /// Keep running totals for every folder down to this depth below the root, so a
        /// rough tree can be drawn while the scan is still going (see `liveTree`). 0 is off.
        public var liveDepth = 0
        /// Priority of the scanning threads. Lower it for scans nobody is waiting for.
        public var qualityOfService = QualityOfService.userInitiated
        public init() {}
    }

    public enum EntryKind: UInt8, Sendable {
        case directory, file, smallFiles
    }

    /// The compact record kept for one entry.
    public struct Entry: Sendable {
        public var allocatedBytes: UInt64
        /// Worker index in the high bits, index into that worker's entries in the low 40;
        /// `rootReference` for children of the scan root.
        public var parent: UInt64
        /// Seconds since 1970.
        public var modified: Int64
        public var nameOffset: UInt32
        /// For `smallFiles`: how many files the record stands for.
        public var count: UInt32
        public var nameLength: UInt16
        public var kind: EntryKind
    }

    /// Everything one thread collected.
    public final class Worker: @unchecked Sendable {
        public fileprivate(set) var totals = ScanTotals()
        public fileprivate(set) var entries = ContiguousArray<Entry>()
        public fileprivate(set) var names = ContiguousArray<UInt8>()
    }

    public static let rootReference = UInt64.max

    /// Running total of one shallow folder, kept while the scan goes. Folders below
    /// `liveDepth` add their files to the deepest bucket above them.
    public struct LiveBucket: Sendable {
        /// Index of the parent bucket; -1 for the root.
        public var parent: Int32
        public var name: String
        /// Bytes of the files counted so far directly in this folder, plus, at the deepest
        /// level, everything below it.
        public var bytes: UInt64
        public var files: UInt32

        public init(parent: Int32, name: String, bytes: UInt64, files: UInt32) {
            self.parent = parent
            self.name = name
            self.bytes = bytes
            self.files = files
        }
    }

    private struct Job {
        var path: String
        var node: UInt64
        var bucket: Int32
        var depth: Int32
    }

    private let options: Options
    private let links = ClaimRegistry()
    private let clones = ClaimRegistry()
    private let condition = NSCondition()
    private var stack: [Job] = []
    /// Directories queued or being scanned. The scan is over when it drops to zero.
    private var outstanding = 0
    private var cancelled = false

    private var progressLock = os_unfair_lock()
    private var progressEntries: UInt64 = 0
    private var progressBytes: UInt64 = 0
    /// Guarded by `progressLock`.
    private var buckets: [LiveBucket] = []

    /// Per-thread results, available once `scan` has returned.
    public private(set) var workers: [Worker] = []

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Entries and bytes counted so far; safe to read from any thread while a scan runs.
    public var progress: (entries: UInt64, bytes: UInt64) {
        os_unfair_lock_lock(&progressLock)
        defer { os_unfair_lock_unlock(&progressLock) }
        return (progressEntries, progressBytes)
    }

    /// A copy of the running totals, for drawing a rough picture before the scan is done.
    /// Empty unless `liveDepth` is set.
    public var liveBuckets: [LiveBucket] {
        os_unfair_lock_lock(&progressLock)
        defer { os_unfair_lock_unlock(&progressLock) }
        return buckets
    }

    /// Asks a running scan to stop; `scan` then returns with what it has.
    public func cancel() {
        condition.lock()
        cancelled = true
        stack.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    public var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled
    }

    /// Drops the per-entry records once they have been turned into a tree.
    public func releaseEntries() {
        workers = []
    }

    /// Scans the volume that `root` is on, starting at `root`. Blocks until done.
    public func scan(root: String) -> ScanTotals {
        guard let rootDevice = deviceID(of: root) else {
            var totals = ScanTotals()
            totals.errors = 1
            return totals
        }

        stack = [Job(path: root, node: Self.rootReference, bucket: 0, depth: 0)]
        outstanding = 1
        if options.liveDepth > 0 {
            os_unfair_lock_lock(&progressLock)
            buckets = [LiveBucket(parent: -1, name: "", bytes: 0, files: 0)]
            os_unfair_lock_unlock(&progressLock)
        }
        let states = (0..<max(1, options.threads)).map { _ in Worker() }
        let group = DispatchGroup()
        for (index, state) in states.enumerated() {
            group.enter()
            let thread = Thread { [self] in
                work(index: index, state: state, rootDevice: rootDevice)
                group.leave()
            }
            thread.qualityOfService = options.qualityOfService
            thread.start()
        }
        group.wait()
        workers = states

        var totals = ScanTotals()
        totals.directories = 1
        for state in states { totals += state.totals }
        return totals
    }

    // MARK: Work distribution

    private func nextJob() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while stack.isEmpty && outstanding > 0 && !cancelled {
            condition.wait()
        }
        return cancelled ? nil : stack.popLast()
    }

    private func finishJob(adding found: [Job]) {
        condition.lock()
        if !cancelled { stack.append(contentsOf: found) }
        outstanding += found.count - 1
        if outstanding == 0 || found.count > 1 {
            condition.broadcast()
        } else if found.count == 1 {
            condition.signal()
        }
        condition.unlock()
    }

    private func work(index: Int, state: Worker, rootDevice: dev_t) {
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        if options.cloneInfo {
            request.forkattr |= attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        }
        if options.privateSize {
            request.forkattr |= attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        }
        var callOptions = UInt64(FSOPT_NOFOLLOW)
        if request.forkattr != 0 {
            callOptions |= UInt64(FSOPT_ATTR_CMN_EXTENDED)
        }

        var found: [Job] = []
        while let job = nextJob() {
            scanDirectory(job, state: state, workerIndex: index, rootDevice: rootDevice,
                          request: &request, callOptions: callOptions,
                          buffer: buffer, bufferSize: bufferSize, found: &found)
            finishJob(adding: found)
            found.removeAll(keepingCapacity: true)
        }
    }

    // MARK: One directory

    private func scanDirectory(_ job: Job, state: Worker, workerIndex: Int, rootDevice: dev_t,
                               request: inout attrlist, callOptions: UInt64,
                               buffer: UnsafeMutableRawPointer, bufferSize: Int, found: inout [Job]) {
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            state.totals.errors += 1
            return
        }
        defer { close(fd) }

        var keepAll = false
        var smallLimit: UInt64 = 0
        var keeping = true
        switch options.retention {
        case .none: keeping = false
        case .everything: keepAll = true
        case .aggregated(let limit): smallLimit = limit
        }
        var smallBytes: UInt64 = 0
        var smallCount: UInt32 = 0
        var smallNewest: Int64 = 0
        var seenEntries: UInt64 = 0
        var seenBytes: UInt64 = 0
        var seenFiles: UInt32 = 0
        // Folders found here that get a live bucket of their own: (index in `found`, name).
        let opensBuckets = options.liveDepth > 0 && Int(job.depth) < options.liveDepth
        var newBuckets: [(job: Int, name: String)] = []

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, callOptions)
            if count < 0 { state.totals.errors += 1 }
            if count <= 0 { break }

            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let entryLength = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += entryLength }

                // Attributes are packed in bit order, and only those flagged in `returned`.
                var field = entry + MemoryLayout<UInt32>.size
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    if field.loadUnaligned(as: UInt32.self) != 0 { state.totals.errors += 1 }
                    field += 4
                }
                var name: UnsafeRawPointer?
                var nameLength = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let reference = field.loadUnaligned(as: attrreference_t.self)
                    name = field + Int(reference.attr_dataoffset)
                    nameLength = max(0, Int(reference.attr_length) - 1)
                    field += MemoryLayout<attrreference_t>.size
                }
                var device = rootDevice
                if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
                    device = field.loadUnaligned(as: dev_t.self)
                    field += 4
                }
                var objectType: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    objectType = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var modified: Int64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    modified = Int64(field.loadUnaligned(as: timespec.self).tv_sec)
                    field += MemoryLayout<timespec>.size
                }
                var flags: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
                    flags = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var fileID: UInt64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }

                let isDirectory = objectType == VDIR.rawValue
                var mountStatus: UInt32 = 0
                var linkCount: UInt32 = 1
                var allocated: UInt64 = 0
                if isDirectory {
                    if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
                        mountStatus = field.loadUnaligned(as: UInt32.self)
                        field += 4
                    }
                } else {
                    if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
                        linkCount = field.loadUnaligned(as: UInt32.self)
                        field += 4
                    }
                    if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                        allocated = UInt64(max(0, field.loadUnaligned(as: off_t.self)))
                        field += 8
                    }
                }
                var privateSize: UInt64 = 0
                if returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 {
                    privateSize = UInt64(max(0, field.loadUnaligned(as: off_t.self)))
                    field += 8
                }
                var cloneID: UInt64 = 0
                if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 {
                    cloneID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                var extendedFlags: UInt64 = 0
                if returned.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 {
                    extendedFlags = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }

                var descend = false
                if isDirectory {
                    state.totals.directories += 1
                    if mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0 || device != rootDevice {
                        state.totals.mountPointsSkipped += 1
                    } else if flags & UInt32(SF_DATALESS) != 0 {
                        state.totals.datalessDirectories += 1
                    } else {
                        descend = name != nil
                    }
                } else {
                    state.totals.files += 1
                    seenFiles += 1
                    state.totals.privateBytes += privateSize
                    let sharesBlocks = extendedFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
                    if sharesBlocks { state.totals.filesSharingBlocks += 1 }

                    // Count every inode once, and every group of clones once.
                    if linkCount > 1, !links.claim(fileID) {
                        state.totals.hardLinkDuplicateBytes += allocated
                        allocated = 0
                    } else if sharesBlocks, cloneID != 0, !clones.claim(cloneID) {
                        state.totals.cloneDuplicateBytes += allocated
                        allocated = 0
                    } else {
                        state.totals.allocatedBytes += allocated
                    }
                }
                seenEntries += 1
                seenBytes += allocated

                var nodeReference = Self.rootReference
                if keeping {
                    if !isDirectory && !keepAll && allocated < smallLimit {
                        smallBytes += allocated
                        smallCount += 1
                        smallNewest = max(smallNewest, modified)
                    } else {
                        nodeReference = UInt64(workerIndex) << 40 | UInt64(state.entries.count)
                        state.entries.append(Entry(
                            allocatedBytes: allocated, parent: job.node, modified: modified,
                            nameOffset: UInt32(truncatingIfNeeded: state.names.count), count: 0,
                            nameLength: UInt16(clamping: nameLength),
                            kind: isDirectory ? .directory : .file))
                        if let name {
                            state.names.append(contentsOf: UnsafeRawBufferPointer(start: name, count: nameLength))
                        }
                    }
                }

                if descend, let name {
                    let child = String(cString: name.assumingMemoryBound(to: CChar.self))
                    let path = job.path.hasSuffix("/") ? job.path + child : job.path + "/" + child
                    if opensBuckets { newBuckets.append((found.count, child)) }
                    found.append(Job(path: path, node: nodeReference, bucket: job.bucket, depth: job.depth + 1))
                }
            }
        }

        if smallCount > 0 {
            state.entries.append(Entry(
                allocatedBytes: smallBytes, parent: job.node, modified: smallNewest,
                nameOffset: UInt32(truncatingIfNeeded: state.names.count), count: smallCount,
                nameLength: 0, kind: .smallFiles))
        }

        os_unfair_lock_lock(&progressLock)
        progressEntries += seenEntries
        progressBytes += seenBytes
        if options.liveDepth > 0 {
            buckets[Int(job.bucket)].bytes += seenBytes
            buckets[Int(job.bucket)].files += seenFiles
            for (index, name) in newBuckets {
                found[index].bucket = Int32(buckets.count)
                buckets.append(LiveBucket(parent: job.bucket, name: name, bytes: 0, files: 0))
            }
        }
        os_unfair_lock_unlock(&progressLock)
    }
}

public func deviceID(of path: String) -> dev_t? {
    var st = stat()
    return lstat(path, &st) == 0 ? st.st_dev : nil
}
