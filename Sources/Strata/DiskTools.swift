import Foundation
import ScanCore

/// Read-only answers about scanned disks, for the MCP server (`MCPServer`). Nothing here
/// changes a file: it reads the scans the app saved, runs fresh scans into memory, and
/// reports what it finds. There is deliberately no way to delete, move or empty anything.
final class DiskTools {
    struct Scan {
        let tree: FileTree
        let catalog: MapCatalog
        /// Scanned by this server rather than loaded from the app's saved scans.
        let isFresh: Bool
    }

    enum Failure: LocalizedError {
        case notAbsolute(String)
        case noScan(String)
        case notFolder(String)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .notAbsolute(let path): return "\(path) is not an absolute path."
            case .noScan(let path):
                return "No scan covers \(path). Open that disk or folder in Strata, or call scan with this path."
            case .notFolder(let path): return "\(path) is not a folder."
            case .notFound(let path): return "\(path) is not in the scan."
            }
        }
    }

    private let folder: URL
    private let home: String
    private var saved: [Scan]?
    private var fresh: [String: Scan] = [:]

    init(folder: URL = ScanStore.folder, home: String = NSHomeDirectory()) {
        self.folder = folder
        self.home = home
    }

    /// For tests: answers from the given scans only.
    init(scans: [Scan], home: String) {
        folder = URL(fileURLWithPath: "/nonexistent")
        self.home = home
        saved = scans
    }

    // MARK: Tools

    func listDisks() -> Report.Disks {
        let disks = ScanTarget.disks().compactMap { target -> Report.Disk? in
            guard let volume = target.volume else { return nil }
            let scan = scans.first { $0.tree.rootPath == target.path }
            return Report.Disk(name: volume.name, path: target.isStartupDisk ? "/" : target.path,
                               total: Report.Size(volume.totalBytes), available: Report.Size(volume.availableBytes),
                               scan: scan.map(Report.ScanInfo.init))
        }
        let volumes = Set(ScanTarget.disks().map(\.path))
        let folders = scans.filter { !volumes.contains($0.tree.rootPath) }.map(Report.ScanInfo.init)
        return Report.Disks(disks: disks, folderScans: folders)
    }

    func showFolder(_ rawPath: String?, limit: Int) throws -> Report.Folder {
        let (scan, index, path) = try locate(rawPath)
        let tree = scan.tree
        guard tree.nodes[index].kind == .directory else { throw Failure.notFolder(path) }
        let children = tree.children(of: index).filter { !tree.nodes[$0].removed && tree.nodes[$0].size > 0 }
        let shown = children.prefix(max(1, limit))
        let rest = children.dropFirst(shown.count)

        var disk: Report.DiskFigures?
        if index == FileTree.root, let volume = scan.catalog.volume {
            disk = Report.DiskFigures(total: Report.Size(volume.totalBytes), available: Report.Size(volume.availableBytes),
                                      unreachable: Report.Size(scan.catalog.hiddenBytes))
        }
        return Report.Folder(
            path: path, size: Report.Size(tree.nodes[index].size), modified: Report.date(tree.nodes[index].modified),
            shareOfDisk: share(tree.nodes[index].size, in: scan), disk: disk, scan: Report.ScanInfo(scan),
            items: shown.map { entry($0, in: scan) },
            notShown: rest.isEmpty ? nil : Report.Rest(count: rest.count, size: Report.Size(rest.reduce(0) { $0 + tree.nodes[$1].size })))
    }

    enum LargestKind: String { case files, folders }

    /// The biggest files below a folder, or the folders where space gathers: folders not
    /// mostly made of one folder inside them, so a long chain of wrappers counts once.
    func findLargest(_ rawPath: String?, kind: LargestKind, limit: Int) throws -> Report.Entries {
        let (scan, start, path) = try locate(rawPath)
        let tree = scan.tree
        var picked: [Int] = []
        walk(tree, from: start) { index in
            let node = tree.nodes[index]
            switch kind {
            case .files:
                if node.kind == .file { picked.append(index) }
            case .folders:
                guard node.kind == .directory, index != start else { return }
                let biggestFolder = tree.children(of: index).filter { tree.nodes[$0].kind == .directory && !tree.nodes[$0].removed }
                    .map { tree.nodes[$0].size }.max() ?? 0
                if Double(biggestFolder) <= 0.5 * Double(node.size) { picked.append(index) }
            }
        }
        picked.sort { tree.nodes[$0].size > tree.nodes[$1].size }
        return Report.Entries(path: path, scan: Report.ScanInfo(scan), items: picked.prefix(max(1, limit)).map { entry($0, in: scan) })
    }

    func findByName(_ query: String, in rawPath: String?, limit: Int) throws -> Report.Entries {
        let (scan, start, path) = try locate(rawPath)
        let tree = scan.tree
        let needle = query.lowercased()
        var found: [Int] = []
        walk(tree, from: start) { index in
            if index != start, tree.nodes[index].kind != .smallItems, tree.name(of: index).lowercased().contains(needle) {
                found.append(index)
            }
        }
        found.sort { tree.nodes[$0].size > tree.nodes[$1].size }
        return Report.Entries(path: path, scan: Report.ScanInfo(scan), items: found.prefix(max(1, limit)).map { entry($0, in: scan) })
    }

    /// What the app lists under Safe to Clean, with sizes. Only reported: cleaning is done in the app.
    func cleanupSuggestions(localSnapshots: () -> Int = LocalSnapshots.count) throws -> Report.Cleanup {
        let startup = ScanTarget.startupDisk.path
        guard let scan = scans.filter({ $0.tree.rootPath == startup }).max(by: { $0.tree.scannedAt < $1.tree.scannedAt }) else {
            throw Failure.noScan("the startup disk")
        }
        let items = CleanupItem.items(in: scan.catalog, home: home).map { item in
            Report.CleanupGroup(name: item.rule.name, note: item.rule.note, size: Report.Size(item.size), folders: item.folders,
                                inTheApp: item.rule.action == .emptyTrash ? "empties the Trash" : "moves what is inside these folders to the Trash")
        }
        return Report.Cleanup(scan: Report.ScanInfo(scan), groups: items, localSnapshots: localSnapshots())
    }

    /// Scans a disk or folder now and answers from that scan for the rest of the session.
    /// Nothing is written: the app's saved scans stay as they are.
    func scan(_ rawPath: String?) throws -> Report.ScanInfo {
        let path = try userPath(rawPath)
        let target: ScanTarget
        if path == "/" || path == MapCatalog.dataVolume {
            target = .startupDisk
        } else if let disk = ScanTarget.disks().first(where: { $0.path == path }) {
            target = disk
        } else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Failure.notFolder(path)
            }
            target = ScanTarget(path: path, isVolume: false)
        }
        disableCloudDownloads()
        var options = VolumeScanner.Options()
        options.threads = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        options.retention = .aggregated(smallFileBytes: AppModel.smallestKept)
        let scanner = VolumeScanner(options: options)
        _ = scanner.scan(root: target.path)
        let tree = FileTree(scanner: scanner, rootPath: target.path, pruneBelow: AppModel.smallestKept)
        let scan = Scan(tree: tree, catalog: MapCatalog(tree: tree, volume: target.volume), isFresh: true)
        fresh[target.path] = scan
        return Report.ScanInfo(scan)
    }

    // MARK: Finding things

    private var scans: [Scan] {
        if saved == nil { saved = loadSaved() }
        var byRoot: [String: Scan] = [:]
        for scan in saved ?? [] where (byRoot[scan.tree.rootPath]?.tree.scannedAt ?? .distantPast) < scan.tree.scannedAt {
            byRoot[scan.tree.rootPath] = scan
        }
        for (root, scan) in fresh { byRoot[root] = scan }
        return Array(byRoot.values)
    }

    /// The app's saved scans, read as they are (unlike `ScanStore.load`, nothing is touched).
    private func loadSaved() -> [Scan] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let disks = ScanTarget.disks()
        return files.filter { $0.lastPathComponent.hasPrefix("scan-") && $0.pathExtension == "strata" }.compactMap { url in
            guard let tree = try? TreeStore.load(from: url) else { return nil }
            let volume = disks.first { $0.path == tree.rootPath }?.volume
            return Scan(tree: tree, catalog: MapCatalog(tree: tree, volume: volume), isFresh: false)
        }
    }

    private func userPath(_ raw: String?) throws -> String {
        var path = (raw ?? "/").trimmingCharacters(in: .whitespaces)
        if path.isEmpty { path = "/" }
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        guard path.hasPrefix("/") else { throw Failure.notAbsolute(path) }
        // Only "." and ".." are resolved: NSString.standardizingPath would also turn
        // /private/var into /var, which the scan does not know.
        var standard = URL(fileURLWithPath: path).standardized.path
        for link in ["/var", "/tmp", "/etc"] where standard == link || standard.hasPrefix(link + "/") {
            standard = "/private" + standard
        }
        return standard.isEmpty ? "/" : standard
    }

    /// The scan that covers a path best (the deepest root, then the newest), and the node for it.
    private func locate(_ raw: String?) throws -> (Scan, Int, String) {
        let path = try userPath(raw)
        let covering = scans.compactMap { scan -> (Scan, String)? in
            let inTree = scan.catalog.treePath(forUserPath: path)
            let root = scan.tree.rootPath
            let covers = inTree == root || inTree.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            return covers ? (scan, inTree) : nil
        }
        guard let (scan, inTree) = covering.max(by: {
            ($0.0.tree.rootPath.count, $0.0.tree.scannedAt) < ($1.0.tree.rootPath.count, $1.0.tree.scannedAt)
        }) else { throw Failure.noScan(path) }
        guard let index = scan.tree.index(ofPath: inTree) else { throw Failure.notFound(path) }
        return (scan, index, path)
    }

    private func walk(_ tree: FileTree, from start: Int, _ visit: (Int) -> Void) {
        var stack = [start]
        while let index = stack.popLast() {
            guard !tree.nodes[index].removed else { continue }
            visit(index)
            stack.append(contentsOf: tree.children(of: index))
        }
    }

    private func entry(_ index: Int, in scan: Scan) -> Report.Entry {
        let node = scan.tree.nodes[index]
        let kind: String
        switch node.kind {
        case .directory: kind = "folder"
        case .file: kind = "file"
        case .smallItems: kind = "small items"
        }
        return Report.Entry(
            name: node.kind == .smallItems ? "\(node.itemCount) small items" : scan.tree.name(of: index),
            path: scan.catalog.userPath(of: index), kind: kind, size: Report.Size(node.size),
            modified: Report.date(node.modified), count: node.kind == .smallItems ? Int(node.itemCount) : nil)
    }

    private func share(_ bytes: UInt64, in scan: Scan) -> String? {
        guard let total = scan.catalog.volume?.totalBytes, total > 0 else { return nil }
        return Format.percent(Double(bytes) / Double(total))
    }
}

/// What the tools answer, encoded as JSON for the MCP client.
enum Report {
    /// Written the way the app writes sizes ("44.8 GB"), which keeps answers short.
    struct Size: Encodable {
        let bytes: UInt64
        init(_ bytes: UInt64) { self.bytes = bytes }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(Format.size(bytes))
        }
    }

    struct ScanInfo: Encodable {
        let root: String
        let scannedAt: String
        let minutesAgo: Int
        let entries: Int
        let source: String

        init(_ scan: DiskTools.Scan) {
            root = scan.catalog.userPath(of: FileTree.root)
            scannedAt = ISO8601DateFormatter().string(from: scan.tree.scannedAt)
            minutesAgo = max(0, Int(Date().timeIntervalSince(scan.tree.scannedAt) / 60))
            entries = scan.tree.entryCount
            source = scan.isFresh ? "scanned in this session" : "saved by the Strata app"
        }
    }

    struct Entry: Encodable {
        let name: String
        let path: String
        let kind: String
        let size: Size
        /// Newest change found at or below the entry.
        let modified: String?
        let count: Int?
    }

    struct Rest: Encodable {
        let count: Int
        let size: Size
    }

    struct DiskFigures: Encodable {
        let total: Size
        let available: Size
        /// In use but out of the scan's reach: local snapshots, the system volume.
        let unreachable: Size
    }

    struct Folder: Encodable {
        let path: String
        let size: Size
        let modified: String?
        let shareOfDisk: String?
        let disk: DiskFigures?
        let scan: ScanInfo
        let items: [Entry]
        let notShown: Rest?
    }

    struct Entries: Encodable {
        let path: String
        let scan: ScanInfo
        let items: [Entry]
    }

    struct Disk: Encodable {
        let name: String
        let path: String
        let total: Size
        let available: Size
        let scan: ScanInfo?
    }

    struct Disks: Encodable {
        let disks: [Disk]
        let folderScans: [ScanInfo]
    }

    struct CleanupGroup: Encodable {
        let name: String
        let note: String
        let size: Size
        let folders: [String]
        let inTheApp: String
    }

    struct Cleanup: Encodable {
        let scan: ScanInfo
        let groups: [CleanupGroup]
        let localSnapshots: Int
    }

    static func date(_ seconds: Int64) -> String? {
        guard seconds > 0 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
