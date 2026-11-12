import Foundation

/// The result of a scan as a compact tree: every folder knows its total size, and a folder's
/// children sit next to each other, largest first. Entries too small to matter on their own
/// are merged into one "small items" node per folder.
public struct FileTree: Sendable {
    public enum Kind: UInt8, Sendable {
        case directory = 0, file = 1
        /// Stands for the entries of a folder that were too small to keep one by one.
        case smallItems = 2
    }

    public struct Node: Sendable {
        /// Allocated bytes of the entry, or of everything below it.
        public var size: UInt64
        /// Newest modification time found at or below the entry, seconds since 1970.
        public var modified: Int64
        public var parent: Int32
        public var firstChild: Int32
        public var childCount: Int32
        /// For `smallItems`: how many entries it stands for.
        public var itemCount: UInt32
        var nameOffset: UInt32
        var nameLength: UInt16
        public var kind: Kind
        /// Set once the entry was deleted through the app; its size is then zero.
        public var removed: Bool
    }

    public internal(set) var nodes: ContiguousArray<Node>
    var names: ContiguousArray<UInt8>
    /// Path the scan started at. Node 0 stands for it.
    public let rootPath: String
    public let scannedAt: Date
    /// Number of files and folders the scan saw, before small ones were merged.
    public let entryCount: Int

    init(nodes: ContiguousArray<Node>, names: ContiguousArray<UInt8>, rootPath: String,
         scannedAt: Date, entryCount: Int) {
        self.nodes = nodes
        self.names = names
        self.rootPath = rootPath
        self.scannedAt = scannedAt
        self.entryCount = entryCount
    }

    public static let root = 0

    public func children(of index: Int) -> Range<Int> {
        let node = nodes[index]
        guard node.childCount > 0 else { return 0..<0 }
        return Int(node.firstChild)..<Int(node.firstChild) + Int(node.childCount)
    }

    /// The entry's own name; the scan root reports its path, small-item nodes report "".
    public func name(of index: Int) -> String {
        if index == Self.root { return rootPath }
        let node = nodes[index]
        let start = Int(node.nameOffset)
        return String(decoding: names[start..<start + Int(node.nameLength)], as: UTF8.self)
    }

    /// Indices from the root down to the entry, both included.
    public func ancestors(of index: Int) -> [Int] {
        var chain: [Int] = []
        var current = index
        while current >= 0 {
            chain.append(current)
            if current == Self.root { break }
            current = Int(nodes[current].parent)
        }
        return chain.reversed()
    }

    /// Full path of the entry. A small-items node reports the folder it belongs to.
    public func path(of index: Int) -> String {
        var parts: [String] = []
        for step in ancestors(of: index).dropFirst() where nodes[step].kind != .smallItems {
            parts.append(name(of: step))
        }
        guard !parts.isEmpty else { return rootPath }
        return (rootPath.hasSuffix("/") ? rootPath : rootPath + "/") + parts.joined(separator: "/")
    }

    /// The node for a path, if the scan kept one. Paths outside the scan root give `nil`.
    public func index(ofPath path: String) -> Int? {
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        if path == base || path == rootPath { return Self.root }
        guard path.hasPrefix(base + "/") else { return nil }
        var current = Self.root
        for part in path.dropFirst(base.count + 1).split(separator: "/") {
            let name = String(part)
            guard let next = children(of: current).first(where: {
                nodes[$0].kind != .smallItems && !nodes[$0].removed && self.name(of: $0) == name
            }) else { return nil }
            current = next
        }
        return current
    }

    /// The deepest node the scan kept on the way to a path: the node itself when it was
    /// kept, otherwise the folder whose small items hold it.
    public func nearestIndex(toPath path: String) -> Int? {
        var candidate = path
        while !candidate.isEmpty {
            if let index = index(ofPath: candidate) { return index }
            guard let slash = candidate.lastIndex(of: "/") else { break }
            candidate = String(candidate[..<slash])
        }
        return nil
    }

    /// Takes a deleted entry out of the totals of every folder above it.
    public mutating func remove(_ index: Int) {
        guard index != Self.root, !nodes[index].removed else { return }
        let size = nodes[index].size
        nodes[index].size = 0
        nodes[index].removed = true
        adjustAncestors(of: index, by: -Int64(clamping: size))
    }

    /// Takes everything inside a folder out of the totals, keeping the folder itself.
    public mutating func removeContents(of index: Int) {
        for child in children(of: index) { remove(child) }
        // Bytes that were never split into children (a folder pruned to a single node).
        if nodes[index].size > 0 {
            let rest = nodes[index].size
            nodes[index].size = 0
            adjustAncestors(of: index, by: -Int64(clamping: rest))
        }
    }

    /// An entry moved elsewhere on the same volume (into the Trash, say): its size leaves
    /// the folders above it and is added to `destination` and the folders above that.
    public mutating func move(_ index: Int, into destination: Int) {
        guard index != Self.root, !nodes[index].removed else { return }
        let size = nodes[index].size
        remove(index)
        add(size, to: destination)
    }

    /// Bytes that arrived in a folder (moved there from elsewhere on the volume).
    public mutating func add(_ bytes: UInt64, to index: Int) {
        nodes[index].size += bytes
        adjustAncestors(of: index, by: Int64(clamping: bytes))
    }

    private mutating func adjustAncestors(of index: Int, by delta: Int64) {
        guard index != Self.root else { return }
        var current = Int(nodes[index].parent)
        while current >= 0 {
            if delta < 0 {
                nodes[current].size -= min(UInt64(-delta), nodes[current].size)
            } else {
                nodes[current].size += UInt64(delta)
            }
            if current == Self.root { break }
            current = Int(nodes[current].parent)
        }
    }
}

extension FileTree {
    /// A rough tree from the running totals of a scan in progress: folders down to the live
    /// depth, each folder's own files folded into one small-items node.
    public init(live buckets: [VolumeScanner.LiveBucket], rootPath: String, pruneBelow: UInt64,
                scannedAt: Date = Date(), entryCount: Int = 0) {
        let count = buckets.count
        var sizes = buckets.map(\.bytes)
        var childLists = [[Int]](repeating: [], count: count)
        // A bucket is always created after its parent, so walking backwards sums bottom-up.
        for index in stride(from: count - 1, through: 1, by: -1) {
            let parent = Int(buckets[index].parent)
            sizes[parent] += sizes[index]
            childLists[parent].append(index)
        }

        var nodes = ContiguousArray<Node>()
        var names = ContiguousArray<UInt8>()
        nodes.append(Node(size: count > 0 ? sizes[0] : 0, modified: 0, parent: -1, firstChild: -1, childCount: 0,
                          itemCount: 0, nameOffset: 0, nameLength: 0, kind: .directory, removed: false))
        var queue: [(old: Int, new: Int)] = count > 0 ? [(0, 0)] : []
        var head = 0
        while head < queue.count {
            let (old, new) = queue[head]
            head += 1
            var mergedSize = buckets[old].bytes
            var mergedCount = buckets[old].files
            var kept: [Int] = []
            for child in childLists[old] {
                if sizes[child] < pruneBelow {
                    mergedSize += sizes[child]
                    mergedCount += 1
                } else {
                    kept.append(child)
                }
            }
            // A folder with nothing kept below it stays a single node.
            guard !kept.isEmpty else { continue }
            kept.sort { sizes[$0] > sizes[$1] }
            let first = nodes.count
            for child in kept {
                let name = Array(buckets[child].name.utf8)
                queue.append((child, nodes.count))
                nodes.append(Node(size: sizes[child], modified: 0, parent: Int32(new), firstChild: -1, childCount: 0,
                                  itemCount: 0, nameOffset: UInt32(names.count), nameLength: UInt16(clamping: name.count),
                                  kind: .directory, removed: false))
                names.append(contentsOf: name)
            }
            if mergedSize > 0 {
                nodes.append(Node(size: mergedSize, modified: 0, parent: Int32(new), firstChild: -1, childCount: 0,
                                  itemCount: max(mergedCount, 1), nameOffset: UInt32(names.count), nameLength: 0,
                                  kind: .smallItems, removed: false))
            }
            nodes[new].firstChild = Int32(first)
            nodes[new].childCount = Int32(nodes.count - first)
        }
        self.init(nodes: nodes, names: names, rootPath: rootPath, scannedAt: scannedAt, entryCount: entryCount)
    }
}

extension FileTree {
    /// Assembles the per-thread records of a finished scan.
    ///
    /// - Parameter pruneBelow: entries smaller than this many bytes (folders by their total)
    ///   are merged into their folder's small-items node.
    public init(scanner: VolumeScanner, rootPath: String, pruneBelow: UInt64, scannedAt: Date = Date()) {
        let workers = scanner.workers

        // Give every record one global index; the scan root gets the last one.
        var offsets: [Int] = []
        var total = 0
        for worker in workers {
            offsets.append(total)
            total += worker.entries.count
        }
        let rootIndex = total

        func globalIndex(_ reference: UInt64) -> Int {
            reference == VolumeScanner.rootReference
                ? rootIndex
                : offsets[Int(reference >> 40)] + Int(reference & 0xFF_FFFF_FFFF)
        }
        func locate(_ global: Int) -> (worker: VolumeScanner.Worker, entry: VolumeScanner.Entry) {
            var workerIndex = offsets.count - 1
            while offsets[workerIndex] > global { workerIndex -= 1 }
            let worker = workers[workerIndex]
            return (worker, worker.entries[global - offsets[workerIndex]])
        }

        // Children lists, built with a counting sort over the parent index.
        var parents = [Int32](repeating: 0, count: total)
        var sizes = [UInt64](repeating: 0, count: total + 1)
        var newest = [Int64](repeating: 0, count: total + 1)
        var firstChild = [Int32](repeating: 0, count: total + 2)
        var seen = 0
        for (workerIndex, worker) in workers.enumerated() {
            for (index, entry) in worker.entries.enumerated() {
                let global = offsets[workerIndex] + index
                let parent = globalIndex(entry.parent)
                parents[global] = Int32(parent)
                sizes[global] = entry.allocatedBytes
                newest[global] = entry.kind == .directory ? 0 : entry.modified
                firstChild[parent + 1] += 1
                seen += entry.kind == .smallFiles ? Int(entry.count) : 1
            }
        }
        for index in 1..<firstChild.count { firstChild[index] += firstChild[index - 1] }
        var cursor = firstChild
        var childList = [Int32](repeating: 0, count: total)
        for global in 0..<total {
            let parent = Int(parents[global])
            childList[Int(cursor[parent])] = Int32(global)
            cursor[parent] += 1
        }

        // Sum sizes upward: walk a depth-first order backwards, so every child is added
        // before its parent is read.
        var order: [Int32] = []
        order.reserveCapacity(total + 1)
        var pending: [Int32] = [Int32(rootIndex)]
        while let node = pending.popLast() {
            order.append(node)
            let start = Int(firstChild[Int(node)]), end = Int(firstChild[Int(node) + 1])
            if start < end { pending.append(contentsOf: childList[start..<end]) }
        }
        for node in order.reversed() where Int(node) != rootIndex {
            let parent = Int(parents[Int(node)])
            sizes[parent] += sizes[Int(node)]
            newest[parent] = max(newest[parent], newest[Int(node)])
        }

        // Emit breadth-first, so that the children of a folder end up next to each other.
        var nodes = ContiguousArray<Node>()
        var names = ContiguousArray<UInt8>()
        nodes.append(Node(size: sizes[rootIndex], modified: newest[rootIndex], parent: -1, firstChild: -1,
                          childCount: 0, itemCount: 0, nameOffset: 0, nameLength: 0,
                          kind: .directory, removed: false))
        var queue: [(old: Int, new: Int)] = [(rootIndex, 0)]
        var head = 0
        var kept: [Int32] = []
        while head < queue.count {
            let (old, new) = queue[head]
            head += 1
            kept.removeAll(keepingCapacity: true)
            var mergedSize: UInt64 = 0
            var mergedCount: UInt32 = 0
            var mergedNewest: Int64 = 0
            for child in childList[Int(firstChild[old])..<Int(firstChild[old + 1])] {
                let index = Int(child)
                let entry = locate(index).entry
                if entry.kind == .smallFiles {
                    mergedSize += sizes[index]
                    mergedCount += entry.count
                    mergedNewest = max(mergedNewest, newest[index])
                } else if sizes[index] < pruneBelow {
                    mergedSize += sizes[index]
                    mergedCount += 1
                    mergedNewest = max(mergedNewest, newest[index])
                } else {
                    kept.append(child)
                }
            }
            kept.sort { sizes[Int($0)] > sizes[Int($1)] }

            let first = nodes.count
            for child in kept {
                let index = Int(child)
                let (worker, entry) = locate(index)
                let nameStart = Int(entry.nameOffset)
                let nameOffset = names.count
                names.append(contentsOf: worker.names[nameStart..<nameStart + Int(entry.nameLength)])
                if entry.kind == .directory { queue.append((index, nodes.count)) }
                nodes.append(Node(size: sizes[index], modified: newest[index], parent: Int32(new),
                                  firstChild: -1, childCount: 0, itemCount: 0,
                                  nameOffset: UInt32(nameOffset), nameLength: entry.nameLength,
                                  kind: entry.kind == .directory ? .directory : .file, removed: false))
            }
            if mergedCount > 0 {
                nodes.append(Node(size: mergedSize, modified: mergedNewest, parent: Int32(new),
                                  firstChild: -1, childCount: 0, itemCount: mergedCount,
                                  nameOffset: UInt32(names.count), nameLength: 0,
                                  kind: .smallItems, removed: false))
            }
            nodes[new].firstChild = Int32(first)
            nodes[new].childCount = Int32(nodes.count - first)
        }

        self.init(nodes: nodes, names: names, rootPath: rootPath, scannedAt: scannedAt, entryCount: seen)
    }
}
