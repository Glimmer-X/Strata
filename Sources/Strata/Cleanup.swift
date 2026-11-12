import Foundation
import ScanCore

/// A kind of thing in the home folder that can go without losing anything: what is in it
/// is rebuilt or downloaded again when needed. Only offered for the startup disk.
struct CleanupRule: Identifiable, Sendable {
    enum Action: Sendable {
        /// Move what is inside the folders to the Trash, keeping the folders.
        case trashContents
        /// Delete what is in the Trash for good.
        case emptyTrash
    }

    let id: String
    let name: String
    let note: String
    /// Folders, relative to the home folder.
    let folders: [String]
    let action: Action

    static let all: [CleanupRule] = [
        CleanupRule(id: "trash", name: String(localized: "废纸篓"), note: String(localized: "清空后空间才会回来"),
                    folders: [".Trash"], action: .emptyTrash),
        CleanupRule(id: "derived-data", name: String(localized: "Xcode 编译缓存"),
                    note: String(localized: "Xcode 下次编译时会重新生成"),
                    folders: ["Library/Developer/Xcode/DerivedData"], action: .trashContents),
        CleanupRule(id: "device-support", name: String(localized: "Xcode 设备支持文件"),
                    note: String(localized: "连接设备时会重新准备"),
                    folders: ["Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport",
                              "Library/Developer/Xcode/tvOS DeviceSupport", "Library/Developer/Xcode/visionOS DeviceSupport"],
                    action: .trashContents),
        CleanupRule(id: "simulator-caches", name: String(localized: "模拟器缓存"),
                    note: String(localized: "模拟器需要时会重新生成"),
                    folders: ["Library/Developer/CoreSimulator/Caches"], action: .trashContents),
        CleanupRule(id: "package-caches", name: String(localized: "软件包缓存"),
                    note: String(localized: "用到时会重新下载"),
                    folders: ["Library/Caches/Homebrew", ".npm/_cacache", "Library/Caches/Yarn", "Library/Caches/pnpm",
                              "Library/Caches/pip", ".cache/pip", ".cache/uv", "Library/Caches/CocoaPods",
                              ".gradle/caches", "Library/Caches/go-build", ".cargo/registry/cache"],
                    action: .trashContents),
        CleanupRule(id: "app-caches", name: String(localized: "应用缓存"), note: String(localized: "App 会按需重新生成"),
                    folders: ["Library/Caches"], action: .trashContents),
        CleanupRule(id: "logs", name: String(localized: "日志"), note: String(localized: "只在排查问题时有用"),
                    folders: ["Library/Logs"], action: .trashContents),
    ]
}

/// One rule as it applies to the current scan.
struct CleanupItem: Identifiable, Sendable {
    let rule: CleanupRule
    /// Folders of the rule that exist, as the Finder knows them.
    let folders: [String]
    /// Bytes they hold, minus what other rules inside them already count.
    let size: UInt64

    var id: String { rule.id }

    /// Below this a suggestion is not worth the attention.
    static let smallest: UInt64 = 10_000_000

    /// The rules worth showing for a scan, largest first.
    static func items(in catalog: MapCatalog, home: String = NSHomeDirectory()) -> [CleanupItem] {
        guard catalog.isStartupDisk, !catalog.isLive else { return [] }
        let tree = catalog.tree
        let everyFolder = CleanupRule.all.flatMap { rule in rule.folders.map { home + "/" + $0 } }

        func size(of path: String) -> UInt64 {
            tree.index(ofPath: catalog.treePath(forUserPath: path)).map { tree.nodes[$0].size } ?? 0
        }

        let items = CleanupRule.all.compactMap { rule -> CleanupItem? in
            // The scan says which folders exist; anything too small to be kept in it is not worth listing.
            let folders = rule.folders.map { home + "/" + $0 }.filter { tree.index(ofPath: catalog.treePath(forUserPath: $0)) != nil }
            var total: UInt64 = 0
            for folder in folders {
                // Another rule's folder inside this one (Homebrew inside Caches) counts there.
                let inner = everyFolder.filter { $0.hasPrefix(folder + "/") }.reduce(0) { $0 + size(of: $1) }
                let own = size(of: folder)
                total += own > inner ? own - inner : 0
            }
            return total >= smallest ? CleanupItem(rule: rule, folders: folders, size: total) : nil
        }
        return items.sorted { $0.size > $1.size }
    }

    /// What `perform` managed to do.
    struct Outcome: Sendable {
        /// For every folder that could be read, the names of the entries still in it:
        /// those another rule covers and those that could not be moved.
        var left: [String: Set<String>] = [:]
        var failures = 0
        /// Where moved entries ended up, when they went to the Trash.
        var trashFolder: String?
    }

    /// Brings the scanned tree in line with what `perform` did. What went to the Trash is
    /// added to the Trash's node, `trash`, when the Trash is part of the scan.
    func record(_ outcome: Outcome, in tree: inout FileTree, catalog: MapCatalog, trash: Int?) {
        for folder in folders {
            guard let index = tree.index(ofPath: catalog.treePath(forUserPath: folder)),
                  let left = outcome.left[folder] else { continue }
            let named = Set(tree.children(of: index).filter { tree.nodes[$0].kind != .smallItems }.map { tree.name(of: $0) })
            // The small items went too when everything that stayed has a node of its own.
            let smallGone = left.isSubset(of: named)
            for child in tree.children(of: index) {
                let gone = tree.nodes[child].kind == .smallItems ? smallGone : !left.contains(tree.name(of: child))
                guard gone else { continue }
                if let trash, !tree.ancestors(of: trash).contains(child) {
                    tree.move(child, into: trash)
                } else {
                    tree.remove(child)
                }
            }
        }
    }

    /// Clears the folders. Slow for big folders; call off the main thread.
    func perform(home: String = NSHomeDirectory()) -> Outcome {
        let manager = FileManager.default
        let skip = Set(CleanupRule.all.filter { $0.id != rule.id }.flatMap { $0.folders.map { home + "/" + $0 } })
        var outcome = Outcome()
        for folder in folders {
            guard let names = try? manager.contentsOfDirectory(atPath: folder) else {
                outcome.failures += 1
                continue
            }
            var left = Set<String>()
            for name in names {
                let path = folder + "/" + name
                if skip.contains(path) {
                    left.insert(name)
                    continue
                }
                do {
                    switch rule.action {
                    case .emptyTrash:
                        try manager.removeItem(atPath: path)
                    case .trashContents:
                        var moved: NSURL?
                        try manager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &moved)
                        if outcome.trashFolder == nil, let moved = moved as URL? {
                            outcome.trashFolder = moved.deletingLastPathComponent().path
                        }
                    }
                } catch {
                    outcome.failures += 1
                    left.insert(name)
                }
            }
            outcome.left[folder] = left
        }
        return outcome
    }
}

/// Local Time Machine snapshots on the startup disk. While they exist, deleted files keep
/// their space until the system removes the snapshots, which it does on its own when room
/// is needed.
enum LocalSnapshots {
    static func count() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.contains("com.apple") }.count
    }
}
