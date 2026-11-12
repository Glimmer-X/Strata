import Darwin

/// What one scan pass found.
public struct ScanTotals: Sendable {
    public var files: UInt64 = 0
    public var directories: UInt64 = 0
    /// Allocated bytes on disk; every hard-linked inode and every group of clones counted once.
    public var allocatedBytes: UInt64 = 0
    /// Allocated bytes skipped because the same inode was already counted through another link.
    public var hardLinkDuplicateBytes: UInt64 = 0
    /// Allocated bytes skipped because another member of the same clone group was already
    /// counted. Filled only when clone information is requested.
    public var cloneDuplicateBytes: UInt64 = 0
    /// Files whose blocks may be shared with a clone. Filled only with clone information.
    public var filesSharingBlocks: UInt64 = 0
    /// Bytes not shared with any clone or snapshot. Filled only when private sizes are requested.
    public var privateBytes: UInt64 = 0
    /// Folders that exist only in iCloud; they are not entered, to avoid downloading them.
    public var datalessDirectories: UInt64 = 0
    public var mountPointsSkipped: UInt64 = 0
    public var errors: UInt64 = 0

    public init() {}

    public static func += (lhs: inout ScanTotals, rhs: ScanTotals) {
        lhs.files += rhs.files
        lhs.directories += rhs.directories
        lhs.allocatedBytes += rhs.allocatedBytes
        lhs.hardLinkDuplicateBytes += rhs.hardLinkDuplicateBytes
        lhs.cloneDuplicateBytes += rhs.cloneDuplicateBytes
        lhs.filesSharingBlocks += rhs.filesSharingBlocks
        lhs.privateBytes += rhs.privateBytes
        lhs.datalessDirectories += rhs.datalessDirectories
        lhs.mountPointsSkipped += rhs.mountPointsSkipped
        lhs.errors += rhs.errors
    }
}

/// Remembers which identifiers (hard-linked inodes, clone groups) were already counted.
/// Shared by all scanning threads; only the rare linked or cloned file reaches it.
public final class ClaimRegistry: @unchecked Sendable {
    private var seen = Set<UInt64>()
    private var lock = os_unfair_lock()

    public init() {}

    /// Returns true the first time an identifier is offered.
    public func claim(_ identifier: UInt64) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return seen.insert(identifier).inserted
    }
}

/// Stops this process from downloading iCloud placeholders merely because it looked at them.
/// Call once before scanning.
public func disableCloudDownloads() {
    setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                   IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
}
