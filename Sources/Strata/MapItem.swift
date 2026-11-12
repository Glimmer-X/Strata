import Foundation
import ScanCore

/// One thing shown on the map or in the list: a folder, a file, or one of the stand-ins for
/// what is not a single entry.
struct MapItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case folder, file
        /// Several small entries of one folder shown as one.
        case small
        /// Space in use that a scan cannot reach: local snapshots, the system volumes.
        case hidden
        /// Space in use that a scan in progress has not reached yet.
        case unscanned
        case free
    }

    /// Index into the scanned tree, or a negative number for stand-ins.
    let id: Int
    var name: String
    var size: UInt64
    var kind: Kind
    /// For `small`: how many entries it stands for.
    var count: Int = 0

    static let freeID = -1
    static let hiddenID = -2

    var isEntry: Bool { id >= 0 && (kind == .folder || kind == .file) }

    var title: String {
        switch kind {
        case .small: return String(localized: "\(count) 个小项")
        case .free: return String(localized: "可用")
        default: return name
        }
    }

    /// Stand-ins that are not part of what was scanned.
    var isOutsideScan: Bool { kind == .hidden || kind == .unscanned || kind == .free }
}

/// Turns the scanned tree into what a view shows for a folder.
struct MapCatalog: Sendable {
    let tree: FileTree
    let volume: VolumeInfo?
    /// True while the first scan is still running and `tree` holds rough running totals.
    var isLive = false

    static let dataVolume = "/System/Volumes/Data"

    var isStartupDisk: Bool { tree.rootPath == Self.dataVolume }

    /// Bytes in use on the volume that the scan did not reach.
    var hiddenBytes: UInt64 {
        guard let volume else { return 0 }
        let scanned = tree.nodes[FileTree.root].size
        let accounted = scanned + volume.availableBytes
        return volume.totalBytes > accounted ? volume.totalBytes - accounted : 0
    }

    /// The whole the root view stands for: the volume when known, else what was scanned.
    var totalBytes: UInt64 {
        volume?.totalBytes ?? tree.nodes[FileTree.root].size
    }

    func item(for index: Int) -> MapItem {
        let node = tree.nodes[index]
        switch node.kind {
        case .directory: return MapItem(id: index, name: tree.name(of: index), size: node.size, kind: .folder)
        case .file: return MapItem(id: index, name: tree.name(of: index), size: node.size, kind: .file)
        case .smallItems: return MapItem(id: index, name: "", size: node.size, kind: .small, count: Int(node.itemCount))
        }
    }

    /// What is directly inside a folder, largest first.
    func children(of index: Int) -> [MapItem] {
        tree.children(of: index).compactMap { child in
            tree.nodes[child].size > 0 ? item(for: child) : nil
        }
    }

    func children(of item: MapItem) -> [MapItem] {
        item.kind == .folder && item.id >= 0 ? children(of: item.id) : []
    }

    /// What a view shows for a folder. At the top of the volume, a folder that holds nearly
    /// everything (Users, then the home folder) is opened up in place, so the picture starts
    /// with the folders people know; free space and unreachable space are added as items.
    func items(in focus: Int) -> [MapItem] {
        var items = children(of: focus)
        guard focus == FileTree.root else { return items }

        var opened = false
        while let first = items.first, first.kind == .folder {
            let total = items.reduce(0) { $0 + $1.size }
            guard Double(first.size) > 0.6 * Double(total) else { break }
            let inside = children(of: first.id)
            guard inside.count > 1 else { break }
            items = (inside + items.dropFirst()).sorted { $0.size > $1.size }
            opened = true
        }
        if opened {
            // A top-level folder can share its name with a home folder (Library); mark it.
            var seen = Set<String>()
            for item in items where tree.nodes[item.id].parent != Int32(FileTree.root) { seen.insert(item.name) }
            items = items.map { item in
                guard item.kind == .folder, tree.nodes[item.id].parent == Int32(FileTree.root), seen.contains(item.name) else { return item }
                var marked = item
                marked.name = "/" + item.name
                return marked
            }
        }
        if hiddenBytes > 0 {
            let name = isLive ? String(localized: "还没扫到")
                : isStartupDisk ? String(localized: "快照与系统") : String(localized: "读不到的部分")
            items.append(MapItem(id: MapItem.hiddenID, name: name, size: hiddenBytes, kind: isLive ? .unscanned : .hidden))
        }
        if let volume, volume.availableBytes > 0 {
            items.append(MapItem(id: MapItem.freeID, name: "", size: volume.availableBytes, kind: .free))
        }
        return items
    }

    /// A name for an item that stays the same from one picture to the next, even across
    /// scans: the path for entries, and fixed names for the stand-ins. Marks with the same key
    /// in two pictures stand for the same thing, which is how a change of picture can move
    /// them instead of replacing them.
    func key(of item: MapItem, in parentKey: String) -> String {
        switch item.kind {
        case .free: return "~free"
        case .hidden, .unscanned: return "~hidden"
        case .small: return parentKey + "/~small"
        case .folder, .file: return item.id >= 0 ? tree.path(of: item.id) : parentKey + "/~" + item.name
        }
    }

    func key(ofFolder index: Int) -> String {
        tree.path(of: index)
    }

    /// Folders from the top down to `focus`, for the path shown above the list.
    func crumbs(to focus: Int) -> [(index: Int, name: String)] {
        tree.ancestors(of: focus).map { index in
            (index, index == FileTree.root ? (volume?.name ?? (tree.rootPath as NSString).lastPathComponent) : tree.name(of: index))
        }
    }

    /// The path as the Finder knows it: the data volume is mounted over the system volume.
    func userPath(of index: Int) -> String {
        let path = tree.path(of: index)
        let prefix = Self.dataVolume
        if path == prefix { return "/" }
        return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count)) : path
    }

    /// The other way round: where a path the Finder knows sits in the scanned tree.
    func treePath(forUserPath path: String) -> String {
        guard isStartupDisk, !path.hasPrefix(Self.dataVolume + "/") else { return path }
        return Self.dataVolume + (path == "/" ? "" : path)
    }
}

/// Keeps the entries worth drawing on their own and folds the rest into one "small items"
/// entry, so a picture never fills with marks too small to see.
///
/// - Parameters:
///   - minimumShare: entries below this fraction of the total are folded.
///   - limit: at most this many entries are kept on their own.
func condensed(_ items: [MapItem], minimumShare: Double, limit: Int, standIn: inout Int) -> [MapItem] {
    let total = items.reduce(0.0) { $0 + Double($1.size) }
    guard total > 0 else { return [] }
    var kept: [MapItem] = []
    var special: [MapItem] = []
    var folded: [MapItem] = []
    for item in items.sorted(by: { $0.size > $1.size }) {
        switch item.kind {
        case .hidden, .unscanned, .free: special.append(item)
        case .small: folded.append(item)
        case .folder, .file:
            if kept.count < limit, Double(item.size) / total >= minimumShare { kept.append(item) } else { folded.append(item) }
        }
    }
    if folded.count == 1, folded[0].kind == .small {
        kept.append(folded[0])
    } else if !folded.isEmpty {
        standIn -= 1
        kept.append(MapItem(id: standIn, name: "", size: folded.reduce(0) { $0 + $1.size }, kind: .small,
                            count: folded.reduce(0) { $0 + ($1.kind == .small ? $1.count : 1) }))
    }
    // Unreachable space, then free space, always close the list.
    return kept + special.sorted { ($0.kind == .free ? 1 : 0) < ($1.kind == .free ? 1 : 0) }
}
