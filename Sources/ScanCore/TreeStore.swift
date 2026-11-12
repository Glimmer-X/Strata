import Foundation

/// Saves a scanned tree to one compressed file and loads it back, so the app can show the
/// last result at once when it opens.
public enum TreeStore {
    public enum StoreError: Error {
        case notATree
        case differentVersion
        case damaged
    }

    private static let magic: UInt32 = 0x5452_5453 // "STRT"
    /// Bump whenever `FileTree.Node` or this file's layout changes; old files are then ignored.
    private static let version: UInt32 = 1

    private struct Header: Codable {
        var rootPath: String
        var scannedAt: Double
        var entryCount: Int
        var nodeCount: Int
        var nameBytes: Int
        var nodeStride: Int
    }

    public static func save(_ tree: FileTree, to url: URL) throws {
        let header = try JSONEncoder().encode(Header(
            rootPath: tree.rootPath, scannedAt: tree.scannedAt.timeIntervalSince1970,
            entryCount: tree.entryCount, nodeCount: tree.nodes.count, nameBytes: tree.names.count,
            nodeStride: MemoryLayout<FileTree.Node>.stride))

        var blob = Data()
        for word in [magic, version, UInt32(header.count)] {
            withUnsafeBytes(of: word.littleEndian) { blob.append(contentsOf: $0) }
        }
        blob.append(header)
        tree.nodes.withUnsafeBytes { blob.append(contentsOf: $0) }
        tree.names.withUnsafeBytes { blob.append(contentsOf: $0) }

        let packed = try (blob as NSData).compressed(using: .lzfse) as Data
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try packed.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> FileTree {
        let packed = try Data(contentsOf: url)
        let blob = try (packed as NSData).decompressed(using: .lzfse) as Data
        guard blob.count >= 12 else { throw StoreError.notATree }

        func word(_ offset: Int) -> UInt32 {
            blob.subdata(in: offset..<offset + 4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
        guard word(0) == magic else { throw StoreError.notATree }
        guard word(4) == version else { throw StoreError.differentVersion }
        let headerLength = Int(word(8))
        guard blob.count >= 12 + headerLength else { throw StoreError.damaged }
        let header = try JSONDecoder().decode(Header.self, from: blob.subdata(in: 12..<12 + headerLength))

        let stride = MemoryLayout<FileTree.Node>.stride
        guard header.nodeStride == stride else { throw StoreError.differentVersion }
        let nodesStart = 12 + headerLength
        let namesStart = nodesStart + header.nodeCount * stride
        guard header.nodeCount > 0, blob.count == namesStart + header.nameBytes else { throw StoreError.damaged }

        var nodes = ContiguousArray<FileTree.Node>()
        nodes.reserveCapacity(header.nodeCount)
        blob.subdata(in: nodesStart..<namesStart).withUnsafeBytes { raw in
            nodes.append(contentsOf: raw.bindMemory(to: FileTree.Node.self))
        }
        let names = ContiguousArray<UInt8>(blob.subdata(in: namesStart..<blob.count))
        return FileTree(nodes: nodes, names: names, rootPath: header.rootPath,
                        scannedAt: Date(timeIntervalSince1970: header.scannedAt), entryCount: header.entryCount)
    }
}
