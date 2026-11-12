import Foundation
import ScanCore

/// A made-up startup disk, for pictures of the app that show nobody's real files.
/// Used by `--snapshot … --demo on`.
enum DemoDisk {
    static let home = "/Users/alex"

    /// A folder: bytes of its own loose files (in GB), how many there are, and what is inside.
    private struct Folder {
        var name: String
        var gb: Double
        var files: UInt32
        var inside: [Folder]

        init(_ name: String, _ gb: Double = 0, files: UInt32 = 0, _ inside: [Folder] = []) {
            self.name = name
            self.gb = gb
            self.files = files > 0 ? files : UInt32(max(1, gb * 180))
            self.inside = inside
        }

        var total: Double { gb + inside.reduce(0) { $0 + $1.total } }
    }

    private static let disk = Folder("", 0.2, [
        Folder("Users", 0, [
            Folder("alex", 0.3, [
                Folder("Library", 0.4, [
                    Folder("Developer", 0.1, [
                        Folder("Xcode", 0.2, [
                            Folder("DerivedData", 1.6, [Folder("Lumen-fkqzdh", 7.4), Folder("Harbor-azbtrc", 5.1), Folder("Cinder-rkpxwo", 3.8)]),
                            Folder("iOS DeviceSupport", 0, [Folder("iPhone17,1 26.1 (23B85)", 6.8), Folder("iPhone16,2 18.6 (22G86)", 4.9)]),
                            Folder("Archives", 3.4),
                        ]),
                        Folder("CoreSimulator", 0.3, [Folder("Devices", 48.0), Folder("Caches", 6.4)]),
                    ]),
                    Folder("Application Support", 1.2, [
                        Folder("Steam", 0.4, [Folder("steamapps", 62.0)]),
                        Folder("MobileSync", 0, [Folder("Backup", 12.3)]),
                        Folder("Adobe", 7.2),
                        Folder("Google", 0.2, [Folder("Chrome", 3.9)]),
                        Folder("Code", 2.3),
                        Folder("Slack", 1.6),
                    ]),
                    Folder("Containers", 3.0, [
                        Folder("com.docker.docker", 21.0),
                        Folder("com.apple.mail", 5.3),
                        Folder("com.apple.Safari", 2.2),
                    ]),
                    Folder("Group Containers", 0.8, [
                        Folder("UBF8T346G9.Office", 3.6),
                        Folder("group.net.whatsapp", 2.8),
                        Folder("group.com.apple.notes", 1.2),
                    ]),
                    Folder("Caches", 2.1, [
                        Folder("com.spotify.client", 4.6),
                        Folder("Homebrew", 3.4),
                        Folder("Google", 2.2),
                        Folder("pip", 1.3),
                    ]),
                    Folder("Messages", 7.8),
                    Folder("Mail", 4.4),
                    Folder("Logs", 1.1),
                ]),
                Folder("Pictures", 0.6, [
                    Folder("Photos Library.photoslibrary", 0.4, [Folder("originals", 160.0), Folder("resources", 13.6)]),
                    Folder("Lightroom", 9.6),
                ]),
                Folder("Movies", 3.0, [
                    Folder("Final Cut Projects.fcpbundle", 88.0),
                    Folder("Screen Recordings", 8.2),
                ]),
                Folder("Documents", 2.2, [
                    Folder("Projects", 0.5, [Folder("Lumen", 9.2), Folder("Harbor", 6.1), Folder("Website", 2.4)]),
                    Folder("Design", 8.8),
                    Folder("Papers", 3.1),
                ]),
                Folder("Music", 0.3, [Folder("Music", 0, [Folder("Media", 21.0)]), Folder("Logic", 6.4)]),
                Folder("Developer", 0.8, [Folder("lumen-app", 6.2), Folder("harbor", 4.3)]),
                Folder("Downloads", 16.5, files: 412),
                Folder("Desktop", 4.1, files: 96),
                Folder(".cache", 0.2, [Folder("huggingface", 38.0), Folder("uv", 1.4)]),
                Folder(".Trash", 5.4, files: 37),
                Folder(".npm", 0.1, [Folder("_cacache", 3.1)]),
                Folder(".gradle", 0, [Folder("caches", 2.4)]),
                Folder(".docker", 2.2),
                Folder(".cargo", 0.1, [Folder("registry", 0, [Folder("cache", 1.8)])]),
            ]),
            Folder("Shared", 1.4),
        ]),
        Folder("Applications", 2.4, files: 3_000, [
            Folder("Xcode.app", 12.6), Folder("Final Cut Pro.app", 6.1), Folder("Adobe Photoshop 2026", 4.4),
            Folder("Logic Pro.app", 3.2), Folder("Docker.app", 2.1), Folder("Blender.app", 1.5),
            Folder("Google Chrome.app", 1.3), Folder("Visual Studio Code.app", 0.7),
        ]),
        Folder("Library", 1.3, [
            Folder("Audio", 0, [Folder("Apple Loops", 8.4)]),
            Folder("Application Support", 4.2),
            Folder("Developer", 0, [Folder("CommandLineTools", 3.6)]),
        ]),
        Folder("private", 0.1, [Folder("var", 0.4, [Folder("vm", 8.0), Folder("folders", 2.3), Folder("db", 1.1)])]),
        Folder("opt", 0, [Folder("homebrew", 6.8)]),
        Folder("usr", 0, [Folder("local", 0.9)]),
    ])

    private static let gigabyte = 1_000_000_000.0

    static func tree(scannedAt: Date) -> FileTree {
        var buckets: [VolumeScanner.LiveBucket] = []
        func add(_ folder: Folder, parent: Int32) {
            buckets.append(VolumeScanner.LiveBucket(parent: parent, name: folder.name,
                                                    bytes: UInt64(folder.gb * gigabyte), files: folder.files))
            let index = Int32(buckets.count - 1)
            for inner in folder.inside { add(inner, parent: index) }
        }
        add(disk, parent: -1)
        return FileTree(live: buckets, rootPath: MapCatalog.dataVolume, pruneBelow: AppModel.smallestKept,
                        scannedAt: scannedAt, entryCount: 2_418_306)
    }

    /// A 1 TB disk with about a fifth free; what is left over is snapshots and the system.
    static var volume: VolumeInfo {
        let total: UInt64 = 994_662_584_320
        let available = UInt64(total) - UInt64((disk.total + 71) * gigabyte)
        return VolumeInfo(name: "Macintosh HD", identifier: "demo", totalBytes: total,
                          availableBytes: available, freeBytes: available)
    }

    /// The startup disk and two others.
    static var disks: [DiskSummary] {
        let main = volume
        return [
            DiskSummary(target: .startupDisk, name: main.name, total: main.totalBytes, available: main.availableBytes),
            DiskSummary(target: ScanTarget(path: "/Volumes/Archive", isVolume: true), name: "Archive",
                        total: 2_000_000_000_000, available: 760_000_000_000),
            DiskSummary(target: ScanTarget(path: "/Volumes/Media", isVolume: true), name: "Media",
                        total: 1_000_000_000_000, available: 212_000_000_000),
        ]
    }
}
