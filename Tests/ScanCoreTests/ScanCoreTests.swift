import Foundation
import Testing
@testable import ScanCore

/// Builds a small folder tree inside the project's temporary directory.
private struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        try write("big/movie.bin", megabytes: 6)
        try write("big/clip.bin", megabytes: 3)
        try write("big/notes/a.txt", bytes: 2_000)
        try write("big/notes/b.txt", bytes: 3_000)
        try write("small/one.txt", bytes: 1_000)
        try write("small/two.txt", bytes: 1_000)
        try write("top.bin", megabytes: 2)
    }

    func write(_ path: String, megabytes: Int) throws { try write(path, bytes: megabytes * 1_048_576) }

    func write(_ path: String, bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Random content, so APFS can neither compress it nor store it sparsely.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, bytes) }
        try data.write(to: url)
    }

    func scan(smallFileBytes: UInt64 = 1_000_000, pruneBelow: UInt64 = 1_000_000) -> (ScanTotals, FileTree) {
        let (totals, tree, _) = scanWithLiveTree(liveDepth: 0, smallFileBytes: smallFileBytes, pruneBelow: pruneBelow)
        return (totals, tree)
    }

    func scanWithLiveTree(liveDepth: Int, smallFileBytes: UInt64 = 1_000_000,
                          pruneBelow: UInt64 = 1_000_000) -> (ScanTotals, FileTree, FileTree) {
        var options = VolumeScanner.Options()
        options.threads = 4
        options.retention = .aggregated(smallFileBytes: smallFileBytes)
        options.liveDepth = liveDepth
        let scanner = VolumeScanner(options: options)
        let totals = scanner.scan(root: root.path)
        let live = FileTree(live: scanner.liveBuckets, rootPath: root.path, pruneBelow: pruneBelow)
        return (totals, FileTree(scanner: scanner, rootPath: root.path, pruneBelow: pruneBelow), live)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func scanCountsEveryEntry() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let (totals, tree) = fixture.scan()

    #expect(totals.files == 7)
    #expect(totals.directories == 4)   // the root, big, big/notes, small
    #expect(totals.errors == 0)
    #expect(tree.nodes[FileTree.root].size == totals.allocatedBytes)
    #expect(tree.entryCount == 10)
}

@Test func treeKeepsLargeEntriesAndMergesSmallOnes() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let (_, tree) = fixture.scan()

    let top = tree.children(of: FileTree.root).map { (tree.name(of: $0), tree.nodes[$0].kind) }
    // "big" and "top.bin" are kept; the folder "small" is below the limit and is merged.
    #expect(top.map(\.0) == ["big", "top.bin", ""])
    #expect(top.last?.1 == .smallItems)

    let big = tree.children(of: FileTree.root).first!
    let inside = tree.children(of: big).map { tree.name(of: $0) }
    #expect(inside == ["movie.bin", "clip.bin", ""])
    let sizes = tree.children(of: big).map { tree.nodes[$0].size }
    #expect(sizes == sizes.sorted(by: >))
    #expect(tree.nodes[big].size == sizes.reduce(0, +))
}

@Test func pathsLeadBackToTheFiles() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let (_, tree) = fixture.scan()

    let big = tree.children(of: FileTree.root).first!
    let movie = tree.children(of: big).first!
    #expect(tree.path(of: movie) == fixture.root.path + "/big/movie.bin")
    #expect(FileManager.default.fileExists(atPath: tree.path(of: movie)))
    let merged = tree.children(of: big).last!
    #expect(tree.path(of: merged) == fixture.root.path + "/big")
}

@Test func removingAnEntryLowersEveryFolderAboveIt() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var (_, tree) = fixture.scan()

    let before = tree.nodes[FileTree.root].size
    let big = tree.children(of: FileTree.root).first!
    let movie = tree.children(of: big).first!
    let movieSize = tree.nodes[movie].size
    tree.remove(movie)
    #expect(tree.nodes[movie].size == 0)
    #expect(tree.nodes[FileTree.root].size == before - movieSize)
    tree.remove(movie)   // a second removal changes nothing
    #expect(tree.nodes[FileTree.root].size == before - movieSize)
}

@Test func savedTreeLoadsBackIdentical() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let (_, tree) = fixture.scan()

    let file = fixture.root.appendingPathComponent("cache/tree.strata")
    try TreeStore.save(tree, to: file)
    let loaded = try TreeStore.load(from: file)
    #expect(loaded.nodes.count == tree.nodes.count)
    #expect(loaded.rootPath == tree.rootPath)
    #expect(loaded.nodes[FileTree.root].size == tree.nodes[FileTree.root].size)
    let big = loaded.children(of: FileTree.root).first!
    #expect(loaded.children(of: big).map { loaded.name(of: $0) } == ["movie.bin", "clip.bin", ""])
}

@Test func aGarbageFileIsRejected() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString)")
    try Data("not a tree".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: (any Error).self) { try TreeStore.load(from: url) }
}

@Test func liveTotalsAddUpToTheFinishedScan() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let (totals, _, live) = fixture.scanWithLiveTree(liveDepth: 1)

    #expect(live.nodes[FileTree.root].size == totals.allocatedBytes)
    // Depth 1 keeps "big" as one node; the root's own file and the small folder are folded.
    let top = live.children(of: FileTree.root).map { (live.name(of: $0), live.nodes[$0].kind) }
    #expect(top.first?.0 == "big")
    #expect(top.last?.1 == .smallItems)
    #expect(live.children(of: live.children(of: FileTree.root).first!).isEmpty)

    let (_, _, deeper) = fixture.scanWithLiveTree(liveDepth: 3)
    #expect(deeper.nodes[FileTree.root].size == totals.allocatedBytes)
}

@Test func pathsFindTheirNodes() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let (_, tree) = fixture.scan()

    let movie = try #require(tree.index(ofPath: fixture.root.path + "/big/movie.bin"))
    #expect(tree.name(of: movie) == "movie.bin")
    #expect(tree.index(ofPath: fixture.root.path) == FileTree.root)
    #expect(tree.index(ofPath: "/somewhere/else") == nil)
    // "small" was merged into the root's small items: the nearest kept node is the root.
    #expect(tree.index(ofPath: fixture.root.path + "/small/one.txt") == nil)
    #expect(tree.nearestIndex(toPath: fixture.root.path + "/small/one.txt") == FileTree.root)
}

@Test func movingAnEntryKeepsTheTotal() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var (_, tree) = fixture.scan()

    let before = tree.nodes[FileTree.root].size
    let big = try #require(tree.index(ofPath: fixture.root.path + "/big"))
    let top = try #require(tree.index(ofPath: fixture.root.path + "/top.bin"))
    let movie = try #require(tree.index(ofPath: fixture.root.path + "/big/movie.bin"))
    let movieSize = tree.nodes[movie].size
    let topSize = tree.nodes[top].size
    let bigSize = tree.nodes[big].size

    tree.move(movie, into: top)
    #expect(tree.nodes[FileTree.root].size == before)
    #expect(tree.nodes[top].size == topSize + movieSize)
    #expect(tree.nodes[big].size == bigSize - movieSize)

    tree.removeContents(of: big)
    #expect(tree.nodes[big].size == 0)
    #expect(!tree.nodes[big].removed)
    #expect(tree.nodes[FileTree.root].size == before - (bigSize - movieSize))
}
