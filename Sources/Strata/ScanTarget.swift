import Foundation
import ScanCore

/// What a scan covers: a whole disk or one folder.
struct ScanTarget: Hashable, Sendable {
    /// Where the scan starts. For the startup disk this is its data volume, which holds
    /// everything that is not the read-only system.
    let path: String
    let isVolume: Bool

    static var startupDisk: ScanTarget {
        let data = MapCatalog.dataVolume
        return ScanTarget(path: FileManager.default.fileExists(atPath: data) ? data : "/", isVolume: true)
    }

    var isStartupDisk: Bool { self == .startupDisk }

    /// The name people know it by: the disk's name, or the folder's.
    var name: String {
        if isVolume { return VolumeInfo.read(path: isStartupDisk ? "/" : path)?.name ?? path }
        return FileManager.default.displayName(atPath: path)
    }

    /// Whether it can be scanned right now: a disk may have been ejected, a folder moved.
    var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Figures of the disk it is on, named the way the Finder names the startup disk.
    /// Folders have none: their picture stands for the folder alone.
    var volume: VolumeInfo? {
        guard isVolume, var info = VolumeInfo.read(path: path) else { return nil }
        if isStartupDisk, let boot = VolumeInfo.read(path: "/") { info.name = boot.name }
        return info
    }

    /// The disks worth offering: local ones that show in the Finder, the startup disk first.
    static func disks() -> [ScanTarget] {
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                         options: [.skipHiddenVolumes]) ?? []
        var result = [startupDisk]
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsLocal == true, values.volumeIsBrowsable == true,
                  values.volumeIsRootFileSystem != true else { continue }
            result.append(ScanTarget(path: url.path, isVolume: true))
        }
        return result
    }

    // MARK: Saving the choice

    private static let pathKey = "target.path"
    private static let volumeKey = "target.isVolume"

    /// The target chosen last time, if it is still there.
    static func remembered() -> ScanTarget? {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: pathKey) else { return nil }
        let target = ScanTarget(path: path, isVolume: defaults.bool(forKey: volumeKey))
        return target.isAvailable ? target : nil
    }

    func remember() {
        UserDefaults.standard.set(path, forKey: Self.pathKey)
        UserDefaults.standard.set(isVolume, forKey: Self.volumeKey)
    }
}

/// The saved scans: one file per disk or folder, in the app's support folder. Only the most
/// recently used few are kept, so the folder stays small however many places are scanned.
enum ScanStore {
    static let keep = 6

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Strata", isDirectory: true)
    }

    static func url(for target: ScanTarget, in folder: URL = folder) -> URL {
        let key: String
        if target.isVolume, let id = VolumeInfo.read(path: target.path)?.identifier, !id.contains("/") {
            key = id
        } else {
            key = (target.isVolume ? "disk-" : "folder-") + stableHash(target.path)
        }
        return folder.appendingPathComponent("scan-\(key).strata")
    }

    /// Saves a scan and drops the oldest saved scans beyond `keep`.
    static func save(_ tree: FileTree, to url: URL) {
        try? TreeStore.save(tree, to: url)
        let folder = url.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let scans = files.filter { $0.lastPathComponent.hasPrefix("scan-") && $0.pathExtension == "strata" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        for old in scans.dropFirst(keep) where old != url {
            try? FileManager.default.removeItem(at: old)
        }
    }

    /// Opening a saved scan counts as using it, so the scans in use are the ones kept.
    static func load(from url: URL) -> FileTree? {
        guard let tree = try? TreeStore.load(from: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return tree
    }

    /// FNV-1a: the same path always gives the same file name, across launches.
    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
