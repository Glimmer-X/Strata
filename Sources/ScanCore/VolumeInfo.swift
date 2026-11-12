import Darwin
import Foundation

/// Size figures of the volume a path is on.
public struct VolumeInfo: Sendable {
    public var name: String
    public var identifier: String
    public var totalBytes: UInt64
    /// Space the system will make available when asked: free blocks plus what it can purge
    /// (local snapshots, caches). This is the figure the Finder shows.
    public var availableBytes: UInt64
    /// Blocks that are free right now.
    public var freeBytes: UInt64

    public init(name: String, identifier: String, totalBytes: UInt64, availableBytes: UInt64, freeBytes: UInt64) {
        self.name = name
        self.identifier = identifier
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.freeBytes = freeBytes
    }

    public static func read(path: String) -> VolumeInfo? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let blockSize = UInt64(fs.f_bsize)
        let total = UInt64(fs.f_blocks) * blockSize
        let free = UInt64(fs.f_bavail) * blockSize

        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeUUIDStringKey, .volumeAvailableCapacityForImportantUsageKey]
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys)
        let important = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
        return VolumeInfo(
            name: values?.volumeName ?? path,
            identifier: values?.volumeUUIDString ?? path,
            totalBytes: total,
            availableBytes: max(important, free),
            freeBytes: free)
    }
}
