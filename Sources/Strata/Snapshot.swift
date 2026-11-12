import AppKit
import ScanCore
import SwiftUI

/// Renders the window to a PNG without showing it, from a saved scan. Used while developing
/// to look at the result as an image.
///
///   Strata --snapshot OUT.png --cache FILE [--scan PATH] [--mode bubbles|flow] [--theme ID]
///          [--size WxH] [--focus sub/folder] [--hover Name[/Inner]] [--tab cleanup]
///          [--state access|scanning] [--seconds N] [--move sub/folder --at SECONDS]
///          [--switch bubbles|flow --at SECONDS] [--menu disks|settings] [--extra-disks N] [--demo on]
///          [--window on]
///
/// `--cache` names the saved scan; it is created by scanning `--scan` (default: the data
/// volume) when missing. `--demo on` pictures a made-up disk instead (`DemoDisk`).
/// `--state scanning` scans `--scan` for `--seconds` (default 6) and pictures the map as it
/// stands at that moment. `--window on` draws it as a Mac window, with rounded corners, the
/// window buttons and a shadow, on a transparent background.
@MainActor
enum Snapshot {
    static func run(_ arguments: [String]) -> Never {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            if arguments[index].hasPrefix("--"), index + 1 < arguments.count {
                values[String(arguments[index].dropFirst(2))] = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        guard let output = values["snapshot"], values["cache"] != nil || values["demo"] != nil else {
            fail("usage: Strata --snapshot OUT.png --cache FILE [--scan PATH] [--mode bubbles|flow] [--theme ID] [--size WxH] [--focus sub/folder] [--hover Name[/Inner]] [--tab cleanup] [--state access|scanning] [--seconds N]")
        }
        var size = CGSize(width: 1280, height: 800)
        if let text = values["size"] {
            let parts = text.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
        }

        _ = NSApplication.shared
        let target = values["scan"].map { ScanTarget(path: $0, isVolume: $0 == ScanTarget.startupDisk.path) } ?? .startupDisk
        let model = AppModel(target: target, interactive: false)
        let theme = Theme.named(values["theme"] ?? "abyss")
        let mode = MapMode(rawValue: values["mode"] ?? "bubbles") ?? .bubbles
        let mapSize = Metrics.mapSize(inWindow: size)

        switch values["state"] {
        case "access":
            model.theme = theme
            model.presentAccessRequest()
        case "scanning":
            let (tree, status) = scanBriefly(root: target.path, seconds: Double(values["seconds"] ?? "") ?? 6)
            model.present(tree, mode: mode, theme: theme, focus: FileTree.root, mapSize: mapSize, live: status)
        default:
            let demo = values["demo"] != nil
            if demo {
                model.volumeOverride = DemoDisk.volume
                model.home = DemoDisk.home
            }
            let tree = demo ? DemoDisk.tree(scannedAt: Date().addingTimeInterval(-2 * 3600))
                : loadOrScan(root: target.path, cache: URL(fileURLWithPath: values["cache"] ?? ""))
            var focus = FileTree.root
            for name in (values["focus"] ?? "").split(separator: "/") {
                guard let next = tree.children(of: focus).first(where: { tree.name(of: $0) == name }) else {
                    fail("no folder named \(name) there")
                }
                focus = next
            }
            model.present(tree, mode: mode, theme: theme, focus: focus, mapSize: mapSize)
            if values["tab"] == "cleanup" { model.panelTab = .cleanup }
            if demo { model.presentDisks(DemoDisk.disks) }
            if let count = Int(values["extra-disks"] ?? "") {
                // Made-up disks, to picture a Mac with several.
                let samples = [("Archive", 2_000_000_000_000.0, 0.62), ("Photos", 1_000_000_000_000.0, 0.81), ("Scratch", 500_000_000_000.0, 0.18)]
                model.presentDisks(model.disks + samples.prefix(count).map { name, total, used in
                    DiskSummary(target: ScanTarget(path: "/Volumes/" + name, isVolume: true), name: name,
                                total: UInt64(total), available: UInt64(total * (1 - used)))
                })
            }
            switch values["menu"] {
            case "disks": model.menu = .disks
            case "settings": model.menu = .settings
            default: break
            }
            if let other = values["switch"].flatMap(MapMode.init(rawValue:)) {
                model.presentSwap(to: other, after: Double(values["at"] ?? "") ?? 0.2)
            }
            if let move = values["move"] {
                // A folder given relative to the scan root, like --focus; ".." goes up one level.
                var target = focus
                for name in move.split(separator: "/") {
                    if name == ".." { target = Int(tree.nodes[target].parent); continue }
                    guard let next = tree.children(of: target).first(where: { tree.name(of: $0) == name }) else {
                        fail("no folder named \(name) there")
                    }
                    target = next
                }
                model.presentMove(to: target, after: Double(values["at"] ?? "") ?? 0.2)
            }
            if let hover = values["hover"] { point(model, at: hover.split(separator: "/").map(String.init)) }
        }

        let window = RootView(model: model, live: false).frame(width: size.width, height: size.height)
        let renderer = values["window"] != nil
            ? ImageRenderer(content: AnyView(WindowFrame(isDark: model.theme.isDark) { window }))
            : ImageRenderer(content: AnyView(window))
        renderer.scale = 2
        renderer.isOpaque = values["window"] == nil
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fail("could not render")
        }
        do {
            try png.write(to: URL(fileURLWithPath: output))
        } catch {
            fail("could not write \(output): \(error.localizedDescription)")
        }
        print("wrote \(output)")
        exit(0)
    }

    private static func loadOrScan(root: String, cache: URL) -> FileTree {
        if let tree = try? TreeStore.load(from: cache), tree.rootPath == root { return tree }
        disableCloudDownloads()
        var options = VolumeScanner.Options()
        options.retention = .aggregated(smallFileBytes: AppModel.smallestKept)
        let scanner = VolumeScanner(options: options)
        _ = scanner.scan(root: root)
        let tree = FileTree(scanner: scanner, rootPath: root, pruneBelow: AppModel.smallestKept)
        try? TreeStore.save(tree, to: cache)
        return tree
    }

    /// Runs a first scan for a while, the way the app does, and stops it.
    private static func scanBriefly(root: String, seconds: Double) -> (FileTree, ScanStatus) {
        disableCloudDownloads()
        var options = VolumeScanner.Options()
        options.retention = .aggregated(smallFileBytes: AppModel.smallestKept)
        options.liveDepth = 5
        let scanner = VolumeScanner(options: options)
        let done = DispatchSemaphore(value: 0)
        Thread {
            _ = scanner.scan(root: root)
            done.signal()
        }.start()
        Thread.sleep(forTimeInterval: seconds)
        let tree = FileTree(live: scanner.liveBuckets, rootPath: root, pruneBelow: AppModel.smallestKept)
        let progress = scanner.progress
        scanner.cancel()
        done.wait()
        return (tree, ScanStatus(isFirst: true, entries: progress.entries, bytes: progress.bytes))
    }

    /// Puts the pointer on the mark with the given name (and optionally one inside it).
    private static func point(_ model: AppModel, at names: [String]) {
        switch model.scene {
        case nil:
            return
        case .bubbles(let scene):
            var candidates = scene.top
            var location: CGPoint?
            for name in names {
                guard let cell = candidates.first(where: { scene.cells[$0].item.title == name }) else { break }
                location = scene.cells[cell].center
                candidates = scene.cells[cell].children
            }
            if let location { model.pointerMoved(to: location) }
        case .flow(let scene):
            guard let name = names.last,
                  let bar = scene.bars.first(where: { $0.item.title == name }) else { return }
            model.pointerMoved(to: CGPoint(x: bar.rect.midX, y: bar.rect.midY))
        }
        model.motion.settle()
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}

/// The window around a still picture: rounded corners, the three window buttons where macOS
/// puts them over a window without a title bar, a thin edge and a soft shadow.
private struct WindowFrame<Content: View>: View {
    let isDark: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.373, blue: 0.341), Color(red: 0.996, green: 0.737, blue: 0.180),
                             Color(red: 0.157, green: 0.784, blue: 0.251)], id: \.self) { color in
                        Circle().fill(color)
                            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                            .frame(width: 12, height: 12)
                    }
                }
                .padding(.leading, 20).padding(.top, 20)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 28, y: 14)
            .padding(.horizontal, 56).padding(.top, 36).padding(.bottom, 76)
    }
}
