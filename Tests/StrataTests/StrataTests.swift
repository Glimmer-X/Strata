import Foundation
import Testing
import ScanCore
@testable import Strata

/// A pretend home folder inside the project's temporary directory.
private struct Home {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
    }

    func write(_ path: String, bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, bytes) }
        try data.write(to: url)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }

    func catalog() -> MapCatalog {
        var options = VolumeScanner.Options()
        options.threads = 2
        options.retention = .aggregated(smallFileBytes: 1_000_000)
        let scanner = VolumeScanner(options: options)
        _ = scanner.scan(root: root.path)
        return MapCatalog(tree: FileTree(scanner: scanner, rootPath: root.path, pruneBelow: 1_000_000), volume: nil)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func emptyingTheTrashClearsItOnDiskAndOnTheMap() throws {
    let home = try Home()
    defer { home.remove() }
    try home.write(".Trash/old.bin", bytes: 3_000_000)
    try home.write(".Trash/note.txt", bytes: 2_000)
    try home.write("Documents/keep.bin", bytes: 2_000_000)
    let catalog = home.catalog()
    let before = catalog.tree.nodes[FileTree.root].size

    let rule = try #require(CleanupRule.all.first { $0.id == "trash" })
    let item = CleanupItem(rule: rule, folders: [home.root.path + "/.Trash"], size: 0)
    let outcome = item.perform(home: home.root.path)
    #expect(outcome.failures == 0)
    #expect(!home.exists(".Trash/old.bin") && !home.exists(".Trash/note.txt"))
    #expect(home.exists(".Trash"))

    var tree = catalog.tree
    item.record(outcome, in: &tree, catalog: catalog, trash: nil)
    let trash = try #require(tree.index(ofPath: home.root.path + "/.Trash"))
    #expect(tree.nodes[trash].size == 0)
    #expect(tree.nodes[FileTree.root].size < before)
    #expect(home.exists("Documents/keep.bin"))
}

@Test func aFolderAnotherRuleCoversIsLeftAlone() throws {
    let home = try Home()
    defer { home.remove() }
    try home.write("Library/Caches/Homebrew/bottle.tar", bytes: 2_000_000)
    try home.write("Library/Caches/com.example.app/blob", bytes: 2_000_000)
    try home.write("Library/Caches/tiny/a", bytes: 1_000)
    let catalog = home.catalog()

    // Clears for good instead of using the Trash, so the test leaves nothing behind.
    let rule = CleanupRule(id: "test", name: "", note: "", folders: ["Library/Caches"], action: .emptyTrash)
    let caches = home.root.path + "/Library/Caches"
    let item = CleanupItem(rule: rule, folders: [caches], size: 0)
    let outcome = item.perform(home: home.root.path)
    #expect(outcome.left[caches] == ["Homebrew"])
    #expect(home.exists("Library/Caches/Homebrew/bottle.tar"))
    #expect(!home.exists("Library/Caches/com.example.app"))
    #expect(!home.exists("Library/Caches/tiny"))

    var tree = catalog.tree
    item.record(outcome, in: &tree, catalog: catalog, trash: nil)
    let folder = try #require(tree.index(ofPath: caches))
    let homebrew = try #require(tree.index(ofPath: caches + "/Homebrew"))
    #expect(tree.nodes[folder].size == tree.nodes[homebrew].size)
}

@Test func onlyTheNewestScansAreKept() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for age in 1...8 {
        let url = folder.appendingPathComponent("scan-old\(age).strata")
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -Double(age) * 3600)], ofItemAtPath: url.path)
    }
    let home = try Home()
    defer { home.remove() }
    try home.write("a.bin", bytes: 1_500_000)
    let fresh = folder.appendingPathComponent("scan-new.strata")
    ScanStore.save(home.catalog().tree, to: fresh)

    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(left.count == ScanStore.keep)
    #expect(left.contains("scan-new.strata"))
    #expect(!left.contains("scan-old8.strata"))
    #expect(ScanStore.load(from: fresh) != nil)
}

@Test func aScanInProgressShowsWhatIsNotReachedYet() throws {
    let tree = FileTree(live: [VolumeScanner.LiveBucket(parent: -1, name: "", bytes: 5_000_000, files: 3)],
                        rootPath: MapCatalog.dataVolume, pruneBelow: 1_000_000)
    let volume = VolumeInfo(name: "Disk", identifier: "id", totalBytes: 100_000_000, availableBytes: 40_000_000, freeBytes: 40_000_000)
    let live = MapCatalog(tree: tree, volume: volume, isLive: true).items(in: FileTree.root)
    #expect(live.map(\.kind).suffix(2) == [.unscanned, .free])
    #expect(live.first { $0.kind == .unscanned }?.size == 55_000_000)

    let done = MapCatalog(tree: tree, volume: volume).items(in: FileTree.root)
    #expect(done.contains { $0.kind == .hidden })
    #expect(!done.contains { $0.kind == .unscanned })
}

@Test func goingIntoAFolderMovesWhatIsInsideIt() throws {
    let home = try Home()
    defer { home.remove() }
    for (index, size) in [9, 6, 4, 3].enumerated() {
        try home.write("Projects/p\(index)/data.bin", bytes: size * 1_000_000)
    }
    try home.write("Music/song.bin", bytes: 15_000_000)
    try home.write("Movies/clip.bin", bytes: 12_000_000)
    let catalog = home.catalog()
    let projects = try #require(catalog.tree.index(ofPath: home.root.path + "/Projects"))
    let size = CGSize(width: 900, height: 640)

    for mode in MapMode.allCases {
        let outer = MapScene.build(mode, catalog: catalog, focus: FileTree.root, size: size)
        let inner = MapScene.build(mode, catalog: catalog, focus: projects, size: size)
        let anchor = try #require(outer.deepestMark(of: Set(catalog.tree.ancestors(of: projects))))
        let morph = Morph(outer: outer, inner: inner, leavesOuter: true, anchor: anchor, bounds: size)
        // Every project shown in the folder's mark carries on into the folder's own picture.
        #expect(morph.matchCount >= 4)

        // Both ends are the pictures at rest: nothing moved, one picture fully there.
        let start = morph.pose(0), end = morph.pose(1)
        #expect(start.outerPlace.allSatisfy(isIdentity))
        #expect(start.outerAlpha.allSatisfy { abs($0 - 1) < 1e-9 })
        #expect(start.innerAlpha.allSatisfy { $0 < 1e-9 })
        #expect(end.innerAlpha.allSatisfy { abs($0 - 1) < 1e-9 })
        #expect(end.outerAlpha.allSatisfy { $0 < 1e-9 })
        #expect(end.innerPlace.allSatisfy(isIdentity))
    }
}

private func isIdentity(_ t: CGAffineTransform) -> Bool {
    abs(t.a - 1) < 1e-6 && abs(t.d - 1) < 1e-6 && abs(t.b) < 1e-6 && abs(t.c) < 1e-6 && abs(t.tx) < 1e-6 && abs(t.ty) < 1e-6
}

// MARK: MCP server

private func demoTools() -> DiskTools {
    let tree = DemoDisk.tree(scannedAt: Date())
    let scan = DiskTools.Scan(tree: tree, catalog: MapCatalog(tree: tree, volume: DemoDisk.volume), isFresh: false)
    return DiskTools(scans: [scan], home: DemoDisk.home)
}

@Test func aFolderIsListedLargestFirstWithFinderPaths() throws {
    let folder = try demoTools().showFolder("~/Library", limit: 3)
    #expect(folder.path == "/Users/alex/Library")
    #expect(folder.items.map(\.name) == ["Application Support", "Developer", "Containers"])
    #expect(folder.items[1].path == "/Users/alex/Library/Developer")
    #expect(folder.notShown?.count ?? 0 > 0)
    #expect(folder.disk == nil)
    #expect(try demoTools().showFolder("/", limit: 5).disk != nil)
}

@Test func theLargestFoldersAreWhereSpaceGathers() throws {
    let found = try demoTools().findLargest("~", kind: .folders, limit: 4)
    // The photo library is mostly its originals folder, so the originals count, not the wrappers.
    #expect(found.items.contains { $0.path == "/Users/alex/Pictures/Photos Library.photoslibrary/originals" })
    #expect(!found.items.contains { $0.name == "Photos Library.photoslibrary" })
    #expect(!found.items.contains { $0.name == "Pictures" })
}

@Test func searchingByNameAndAskingForCleanup() throws {
    let tools = demoTools()
    let caches = try tools.findByName("cache", in: "~", limit: 50)
    #expect(caches.items.contains { $0.path == "/Users/alex/Library/Caches" })
    #expect(caches.items.contains { $0.path == "/Users/alex/.cache" })
    let cleanup = try tools.cleanupSuggestions(localSnapshots: { 0 })
    #expect(cleanup.groups.contains { $0.folders == ["/Users/alex/Library/Developer/Xcode/DerivedData"] })
    #expect(throws: DiskTools.Failure.self) { try tools.showFolder("Library", limit: 5) }
    #expect(throws: DiskTools.Failure.self) { try tools.showFolder("/Volumes/Elsewhere", limit: 5) }
    #expect(try tools.showFolder("/private/var", limit: 5).path == "/private/var")
    #expect(try tools.showFolder("/var/", limit: 5).path == "/private/var")
}

@Test func theMCPServerOnlyOffersToolsThatRead() throws {
    let session = MCPServer.Session(tools: demoTools())
    let start = session.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
    #expect((start?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-03-26")
    #expect(session.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

    let list = session.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    let tools = try #require((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(tools.count == 6)
    for tool in tools {
        let hints = try #require(tool["annotations"] as? [String: Any])
        #expect(hints["readOnlyHint"] as? Bool == true)
        #expect(hints["destructiveHint"] as? Bool == false)
        let name = try #require(tool["name"] as? String)
        #expect(!["delete", "remove", "trash", "move", "clean_up", "empty"].contains { name.contains($0) })
    }

    let call = session.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"show_folder","arguments":{"path":"~","limit":2}}}"#)
    let result = try #require(call?["result"] as? [String: Any])
    #expect(result["isError"] == nil)
    let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    #expect(text.contains("\"path\":\"/Users/alex\""))

    let unknown = session.handle(#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#)
    #expect((unknown?["error"] as? [String: Any])?["code"] as? Int == -32601)
}
