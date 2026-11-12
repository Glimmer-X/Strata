import AppKit
import ScanCore
import SwiftUI

/// Sizes shared by the window layout and by whoever needs to know the map's size up front.
enum Metrics {
    static let panelWidth: CGFloat = 340
    static let barHeight: CGFloat = 54
    static let mapInsets = EdgeInsets(top: 0, leading: 6, bottom: 22, trailing: 22)

    static func mapSize(inWindow size: CGSize) -> CGSize {
        CGSize(width: size.width - panelWidth - mapInsets.leading - mapInsets.trailing,
               height: size.height - barHeight - mapInsets.bottom)
    }
}

/// What the small card next to the pointer says.
struct HoverInfo: Equatable {
    var title: String
    var size: String
    var share: String
    var detail: String
}

/// Where the pointer is and what it is over. Kept apart from the app model so that moving
/// the pointer redraws only the card that follows it.
final class PointerModel: ObservableObject {
    @Published var location: CGPoint?
    @Published var info: HoverInfo?
}

/// A disk that can be looked at, with its figures.
struct DiskSummary: Hashable, Identifiable {
    let target: ScanTarget
    let name: String
    let total: UInt64
    let available: UInt64

    var id: String { target.path }
    var used: UInt64 { total > available ? total - available : 0 }
    var usedShare: Double { total > 0 ? Double(used) / Double(total) : 0 }

    init(target: ScanTarget, name: String, total: UInt64, available: UInt64) {
        self.target = target
        self.name = name
        self.total = total
        self.available = available
    }

    init?(_ target: ScanTarget) {
        guard let volume = target.volume else { return nil }
        self.init(target: target, name: volume.name, total: volume.totalBytes, available: volume.availableBytes)
    }
}

/// A scan under way.
struct ScanStatus: Equatable {
    /// The first scan of a disk or folder: the map is drawn from its running totals. Later
    /// scans run quietly behind the last result and replace it when done.
    var isFirst: Bool
    var entries: UInt64 = 0
    var bytes: UInt64 = 0
    /// Entries the previous scan saw, to tell how far this one is.
    var expected: Int?

    var fraction: Double? {
        expected.map { min(0.99, Double(entries) / Double(max($0, 1))) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case checking, needsAccess, ready
    }

    enum PanelTab {
        case largest, cleanup
    }

    /// The small menus that float over the window.
    enum Menu {
        /// Under the name at the top of the panel.
        case disks
        /// Under the gear above the map.
        case settings
    }

    @Published var phase: Phase = .checking
    @Published private(set) var target: ScanTarget
    @Published var mode: MapMode {
        didSet {
            guard mode != oldValue else { return }
            if interactive { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
            rebuild(.swap)
        }
    }
    @Published var theme: Theme {
        didSet { if interactive { UserDefaults.standard.set(theme.id, forKey: "theme") } }
    }
    @Published private(set) var catalog: MapCatalog?
    @Published private(set) var focus = FileTree.root
    @Published private(set) var scene: MapScene?
    @Published private(set) var scan: ScanStatus?
    @Published private(set) var cleanup: [CleanupItem] = []
    /// The cleanup suggestion being carried out.
    @Published private(set) var cleaning: String?
    @Published var panelTab = PanelTab.largest
    @Published private(set) var disks: [DiskSummary] = []
    /// The menu open over the window, if any.
    @Published var menu: Menu?
    /// The language chosen in the settings; it takes effect when the app opens again.
    @Published private(set) var language = AppLanguage.saved
    private let launchLanguage = AppLanguage.saved
    /// True while something on the map is moving and frames must keep coming.
    @Published var animating = false
    /// Id of the top-level item under the pointer, on the map or in the list.
    @Published private(set) var highlighted: Int?

    let motion = MotionState()
    let pointer = PointerModel()
    /// The flow bar whose family is kept bright; stays set while its lift fades out.
    private(set) var flowFocus: Int?
    private(set) var mapSize = CGSize.zero
    /// The folder the picture on screen shows; differs from `focus` while a new one is built.
    private var shownFocus = FileTree.root
    private var generation = 0
    private var scanner: VolumeScanner?
    private var progressTimer: Timer?
    private var buildingLiveTree = false
    private var snapshotCount = 0
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?

    /// A saved scan to show instead of the target's own, for trying the app while developing.
    var cacheOverride: URL?
    /// Figures of the disk to use instead of reading them, for pictures of made-up data.
    var volumeOverride: VolumeInfo?
    /// The home folder the cleanup suggestions look in.
    var home = NSHomeDirectory()
    /// False for still pictures: choices are not saved and the system is not watched.
    let interactive: Bool

    nonisolated static let smallestKept: UInt64 = 1_000_000
    /// Saved results older than this are refreshed quietly when they are shown.
    static let refreshAge: TimeInterval = 10 * 60

    init(target: ScanTarget? = nil, interactive: Bool = true) {
        self.interactive = interactive
        let defaults = UserDefaults.standard
        mode = MapMode(rawValue: (interactive ? defaults.string(forKey: "mode") : nil) ?? "") ?? .bubbles
        theme = Theme.named((interactive ? defaults.string(forKey: "theme") : nil) ?? "")
        self.target = target ?? (interactive ? ScanTarget.remembered() : nil) ?? .startupDisk
    }

    // MARK: Starting up

    /// Shows the last scan of the chosen disk if there is one, otherwise scans it.
    func start() {
        guard phase == .checking else { return }
        if interactive {
            watchSystem()
            Task.detached(priority: .utility) {
                let count = LocalSnapshots.count()
                await MainActor.run { self.snapshotCount = count }
            }
        }
        refreshDisks()
        load()
    }

    private func load() {
        let url = cacheOverride ?? ScanStore.url(for: target)
        if let tree = ScanStore.load(from: url), cacheOverride != nil || tree.rootPath == target.path {
            if cacheOverride != nil { target = ScanTarget(path: tree.rootPath, isVolume: true) }
            show(tree)
            if cacheOverride == nil, Date().timeIntervalSince(tree.scannedAt) > Self.refreshAge, canScan { beginScan() }
        } else if canScan {
            beginScan()
        } else {
            catalog = nil
            scene = nil
            phase = .needsAccess
        }
    }

    /// Whether folders that macOS protects can be read. There is no API to ask; trying is the test.
    static var hasFullDiskAccess: Bool {
        let probes = ["/Library/Application Support/com.apple.TCC", NSHomeDirectory() + "/Library/Safari"]
        return probes.contains { (try? FileManager.default.contentsOfDirectory(atPath: $0)) != nil }
    }

    /// Only the startup disk needs the extra access to be worth scanning.
    private var canScan: Bool { !target.isStartupDisk || Self.hasFullDiskAccess }

    func openAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func accessGranted() {
        if Self.hasFullDiskAccess { beginScan() } else { NSSound.beep() }
    }

    /// Keeps the list of disks current, and the result fresh when the app comes back after a while.
    private func watchSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.disksChanged() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshDisks()
                self?.refreshIfStale()
            }
        })
        // Esc closes the disk menu, or goes back up one folder.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  NSApp.modalWindow == nil, let self else { return event }
            return MainActor.assumeIsolated { self.escape() } ? nil : event
        }
    }

    /// Returns false when Esc has nothing to do here.
    private func escape() -> Bool {
        if menu != nil {
            show(menu: nil)
            return true
        }
        guard focus != FileTree.root, canNavigate else { return false }
        goUp()
        return true
    }

    /// Opens a menu, or closes the open one with `nil`. Asking for the open menu closes it.
    func show(menu wanted: Menu?) {
        let next = wanted == menu ? nil : wanted
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { menu = next }
        if next == .disks { refreshDisks() }
    }

    private func refreshIfStale() {
        guard phase == .ready, scanner == nil, cacheOverride == nil, let catalog, !catalog.isLive,
              Date().timeIntervalSince(catalog.tree.scannedAt) > 3 * Self.refreshAge, canScan else { return }
        beginScan()
    }

    // MARK: Settings

    func choose(_ newLanguage: AppLanguage) {
        language = newLanguage
        if interactive { newLanguage.save() }
    }

    var languageNeedsRelaunch: Bool { language != launchLanguage }

    func relaunch() {
        AppLanguage.relaunch()
    }

    // MARK: Choosing what to scan

    func refreshDisks() {
        let fresh = ScanTarget.disks().compactMap(DiskSummary.init)
        if fresh != disks { disks = fresh }
    }

    private func disksChanged() {
        refreshDisks()
        if !target.isAvailable { select(.startupDisk) }
    }

    /// Looks at another disk or folder. The picture on screen stays until the new one is
    /// ready, then shrinks away as the new one pops up.
    func select(_ newTarget: ScanTarget) {
        if menu != nil { show(menu: nil) }
        guard newTarget != target || catalog == nil else { return }
        cancelScan()
        if interactive { newTarget.remember() }
        cacheOverride = nil
        withAnimation(.easeInOut(duration: 0.3)) {
            target = newTarget
            // The old disk's numbers go now; its picture stays until the new one replaces it.
            catalog = nil
            focus = FileTree.root
            shownFocus = FileTree.root
            cleanup = []
            panelTab = .largest
            load()
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "扫描")
        panel.message = String(localized: "选一个文件夹，只看它里面的空间")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(ScanTarget(path: url.path, isVolume: false))
    }

    // MARK: Scanning

    /// Scans the target. The first time, the map grows as the scan goes; later scans run at a
    /// lower priority behind the result on screen and swap in when done.
    func beginScan() {
        guard scanner == nil, target.isAvailable else { return }
        let first = catalog == nil || catalog?.isLive == true
        let cores = ProcessInfo.processInfo.activeProcessorCount
        var options = VolumeScanner.Options()
        options.threads = first ? min(8, max(2, cores - 2)) : min(4, max(2, cores / 3))
        options.qualityOfService = first ? .userInitiated : .utility
        options.retention = .aggregated(smallFileBytes: Self.smallestKept)
        options.liveDepth = first ? 5 : 0
        let scanner = VolumeScanner(options: options)
        self.scanner = scanner
        scan = ScanStatus(isFirst: first, expected: first ? nil : catalog?.tree.entryCount)

        if first {
            let empty = FileTree(live: [], rootPath: target.path, pruneBelow: Self.smallestKept)
            catalog = MapCatalog(tree: empty, volume: target.volume, isLive: true)
            focus = FileTree.root
            shownFocus = FileTree.root
            phase = .ready
            rebuild(.swap)
        }

        var ticks = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.scanner === scanner else { return }
                let progress = scanner.progress
                self.scan?.entries = progress.entries
                self.scan?.bytes = progress.bytes
                ticks += 1
                if first, ticks % 12 == 0 { self.growLiveTree(from: scanner) }
            }
        }

        let root = target.path, url = ScanStore.url(for: target)
        Task.detached(priority: first ? .userInitiated : .utility) {
            disableCloudDownloads()
            _ = scanner.scan(root: root)
            guard !scanner.isCancelled else { return }
            let tree = FileTree(scanner: scanner, rootPath: root, pruneBelow: AppModel.smallestKept)
            scanner.releaseEntries()
            ScanStore.save(tree, to: url)
            await MainActor.run { self.finishScan(tree, from: scanner) }
        }
    }

    /// Redraws the map from the running totals of the first scan.
    private func growLiveTree(from scanner: VolumeScanner) {
        guard !buildingLiveTree else { return }
        buildingLiveTree = true
        let root = target.path
        Task.detached(priority: .userInitiated) {
            let tree = FileTree(live: scanner.liveBuckets, rootPath: root, pruneBelow: AppModel.smallestKept)
            await MainActor.run {
                self.buildingLiveTree = false
                guard self.scanner === scanner, let catalog = self.catalog, catalog.isLive else { return }
                self.catalog = MapCatalog(tree: tree, volume: catalog.volume, isLive: true)
                self.rebuild(.update)
            }
        }
    }

    private func finishScan(_ tree: FileTree, from finished: VolumeScanner) {
        guard scanner === finished else { return }
        stopProgress()
        // Stay in the same folder when it still exists.
        let path = catalog.flatMap { $0.isLive ? nil : $0.tree.path(of: focus) }
        catalog = MapCatalog(tree: tree, volume: target.volume)
        focus = path.flatMap { tree.index(ofPath: $0) } ?? FileTree.root
        shownFocus = focus
        phase = .ready
        rebuild(.update)
        updateCleanup()
        refreshDisks()
    }

    func cancelScan() {
        scanner?.cancel()
        stopProgress()
    }

    private func stopProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        scanner = nil
        scan = nil
    }

    /// Shows a finished scan.
    func show(_ tree: FileTree) {
        catalog = MapCatalog(tree: tree, volume: target.volume)
        focus = FileTree.root
        shownFocus = FileTree.root
        phase = .ready
        rebuild(.swap)
        updateCleanup()
    }

    private func updateCleanup() {
        cleanup = catalog.map { CleanupItem.items(in: $0, home: home) } ?? []
        if cleanup.isEmpty { panelTab = .largest }
    }

    // MARK: Moving around

    func setMapSize(_ size: CGSize) {
        guard abs(size.width - mapSize.width) > 0.5 || abs(size.height - mapSize.height) > 0.5 else { return }
        let first = mapSize == .zero
        mapSize = size
        rebuild(first ? .popIn : .none)
    }

    /// Whether the map can be clicked into; not while it is drawn from running totals.
    var canNavigate: Bool { catalog?.isLive == false }

    func open(_ item: MapItem) {
        guard let catalog, canNavigate, item.kind == .folder, item.id >= 0, !catalog.children(of: item.id).isEmpty else { return }
        go(to: item.id)
    }

    /// Shows a folder found some other way (a cleanup suggestion): the folder itself when it
    /// has something to show, otherwise the folder it is in.
    func reveal(inMap userPath: String) {
        guard let catalog, canNavigate,
              var index = catalog.tree.nearestIndex(toPath: catalog.treePath(forUserPath: userPath)) else { return }
        if catalog.children(of: index).isEmpty, index != FileTree.root { index = Int(catalog.tree.nodes[index].parent) }
        go(to: index)
    }

    func go(to index: Int) {
        guard index != focus, canNavigate, !motion.isTransitioning else { return }
        withAnimation(.easeInOut(duration: 0.3)) { focus = index }
        rebuild(.navigate)
    }

    func goUp() {
        guard let catalog, focus != FileTree.root else { return }
        go(to: Int(catalog.tree.nodes[focus].parent))
    }

    /// Why a picture is rebuilt, which decides how it replaces the one on screen.
    enum Change: Sendable {
        /// A first picture.
        case popIn
        /// Another view or another disk.
        case swap
        /// The same folder with new numbers.
        case update
        /// The window was resized.
        case none
        /// The focus moved: zoom into or out of the folder.
        case navigate
    }

    /// Lays out the current view in the background and swaps it in when ready.
    func rebuild(_ change: Change) {
        guard let catalog, mapSize.width > 0 else { return }
        generation += 1
        let wanted = generation
        let focus = focus, size = mapSize, mode = mode
        Task.detached(priority: .userInitiated) {
            let scene = MapScene.build(mode, catalog: catalog, focus: focus, size: size)
            await MainActor.run {
                guard wanted == self.generation else { return }
                self.install(scene, change: change)
            }
        }
    }

    /// The same, at once. For still pictures.
    func rebuildNow() {
        guard let catalog, mapSize.width > 0 else { return }
        generation += 1
        install(MapScene.build(mode, catalog: catalog, focus: focus, size: mapSize), change: .none)
    }

    private func install(_ new: MapScene, change: Change) {
        if ProcessInfo.processInfo.environment["STRATA_TRACE"] != nil {
            FileHandle.standardError.write(Data("scene ready: \(new.mode), map \(Int(mapSize.width))×\(Int(mapSize.height))\n".utf8))
        }
        let previous = scene
        let transition: MapTransition
        switch change {
        case .popIn: transition = .popIn
        case .swap: transition = previous == nil ? .popIn : .swap
        case .none: transition = .none
        case .update: transition = morph(from: previous, to: new, navigating: false)
        case .navigate: transition = morph(from: previous, to: new, navigating: true)
        }
        let leavingFocus = flowFocus
        scene = new
        shownFocus = focus
        flowFocus = nil
        highlighted = nil
        pointer.info = nil
        motion.begin(transition, from: previous, flowFocus: leavingFocus)
        animating = true
    }

    /// Going into a folder spreads what is inside its mark over the map; going up gathers
    /// the picture back into the folder's mark. New numbers for the same folder move the
    /// marks to their new places.
    private func morph(from previous: MapScene?, to new: MapScene, navigating: Bool) -> MapTransition {
        guard let previous else { return .popIn }
        guard previous.mode == new.mode else { return .swap }
        if navigating, let tree = catalog?.tree {
            let inward = tree.ancestors(of: focus), outward = tree.ancestors(of: shownFocus)
            if inward.contains(shownFocus) {
                return .morph(Morph(outer: previous, inner: new, leavesOuter: true,
                                    anchor: previous.deepestMark(of: Set(inward)), bounds: mapSize))
            }
            if outward.contains(focus) {
                return .morph(Morph(outer: new, inner: previous, leavesOuter: false,
                                    anchor: new.deepestMark(of: Set(outward)), bounds: mapSize))
            }
        }
        return .morph(Morph(outer: previous, inner: new, leavesOuter: true, anchor: nil, bounds: mapSize))
    }

    /// A transition finished: pick up what the pointer is over now.
    func transitionEnded() {
        if let location = pointer.location { pointerMoved(to: location) }
    }

    // MARK: Pointer

    /// The pointer moved over the map (`nil` when it left).
    func pointerMoved(to location: CGPoint?) {
        pointer.location = location
        guard let location, !motion.isTransitioning, let scene else {
            setTargets([], top: nil, info: nil)
            return
        }
        switch scene {
        case .bubbles(let scene):
            let chain = scene.hit(location)
            setTargets(Set(chain), top: chain.first.map { scene.cells[$0].item.id },
                       info: chain.last.map { info(for: scene.cells[$0].item) })
        case .flow(let scene):
            let bar = scene.hit(location)
            if let bar { flowFocus = bar }
            var top = bar
            while let current = top, let parent = scene.bars[current].parent { top = parent }
            setTargets(bar.map { [$0] } ?? [], top: top.map { scene.bars[$0].item.id },
                       info: bar.map { info(for: scene.bars[$0].item) })
        }
    }

    /// A row of the list is under the pointer: lift its mark on the map.
    func listHover(_ item: MapItem?) {
        guard let item, let scene else {
            setTargets([], top: nil, info: nil)
            return
        }
        switch scene {
        case .bubbles(let scene):
            let cell = scene.top.first { scene.cells[$0].item.id == item.id }
            setTargets(cell.map { [$0] } ?? [], top: item.id, info: nil)
        case .flow(let scene):
            let bar = scene.bars.firstIndex { $0.level == 0 && $0.item.id == item.id }
            if let bar { flowFocus = bar }
            setTargets(bar.map { [$0] } ?? [], top: item.id, info: nil)
        }
    }

    private func setTargets(_ targets: Set<Int>, top: Int?, info: HoverInfo?) {
        if motion.targets != targets {
            motion.targets = targets
            animating = true
        }
        if highlighted != top { highlighted = top }
        if pointer.info != info { pointer.info = info }
    }

    /// The map was clicked: go into the outermost folder under the pointer.
    func clicked(at location: CGPoint) {
        guard !motion.isTransitioning, let scene else { return }
        switch scene {
        case .bubbles(let scene):
            guard let first = scene.hit(location).first else { return }
            open(scene.cells[first].item)
        case .flow(let scene):
            guard let bar = scene.hit(location) else { return }
            open(scene.bars[bar].item)
        }
    }

    /// The entry under a point, innermost first, for the context menu.
    func entry(at location: CGPoint) -> MapItem? {
        guard canNavigate, let scene else { return nil }
        switch scene {
        case .bubbles(let scene):
            return scene.hit(location).reversed().map { scene.cells[$0].item }.first { $0.isEntry }
        case .flow(let scene):
            guard let bar = scene.hit(location) else { return nil }
            return scene.bars[bar].item.isEntry ? scene.bars[bar].item : nil
        }
    }

    private func info(for item: MapItem) -> HoverInfo {
        let total = Double(catalog?.totalBytes ?? 1)
        let detail: String
        switch item.kind {
        case .free: detail = String(localized: "需要时系统可以腾出的空间")
        case .hidden:
            detail = catalog?.isStartupDisk == true
                ? String(localized: "本地快照、系统卷和读不到的文件夹") : String(localized: "扫描读不到的部分")
        case .unscanned: detail = String(localized: "扫描还没数到这一部分")
        case .small: detail = String(localized: "这个文件夹里比较小的东西")
        case .folder, .file: detail = item.id >= 0 ? (catalog?.userPath(of: item.id) ?? "") : ""
        }
        return HoverInfo(title: item.title, size: Format.size(item.size),
                         share: Format.percent(Double(item.size) / max(total, 1)), detail: detail)
    }

    // MARK: Acting on entries

    func reveal(_ item: MapItem) {
        guard let catalog, item.isEntry else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: catalog.userPath(of: item.id))])
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// What to add when space may not come back at once.
    private var snapshotNote: String {
        guard target.isStartupDisk, snapshotCount > 0 else { return "" }
        return "\n\n" + String(localized: "这台 Mac 有本地快照，部分空间要等系统自动清掉快照后才会真正回来。")
    }

    /// Asks, then moves the entry to the Trash. On the same disk its size moves into the Trash
    /// on the map too, because the space is not free until the Trash is emptied.
    func trash(_ item: MapItem) {
        guard let catalog, item.isEntry, canNavigate else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "把“\(item.name)”移到废纸篓？")
        alert.informativeText = String(localized: "它占 \(Format.size(item.size))。清空废纸篓之后，空间才会腾出来。") + snapshotNote
        alert.addButton(withTitle: String(localized: "移到废纸篓"))
        alert.addButton(withTitle: String(localized: "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var moved: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: catalog.userPath(of: item.id)), resultingItemURL: &moved)
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = String(localized: "没能移到废纸篓")
            failure.runModal()
            return
        }
        var tree = catalog.tree
        let folder = (moved as URL?)?.deletingLastPathComponent().path
        if let destination = trashIndex(in: catalog, for: folder), !tree.ancestors(of: destination).contains(item.id) {
            tree.move(item.id, into: destination)
        } else {
            tree.remove(item.id)
        }
        apply(tree)
    }

    /// The node standing for a Trash folder, when that folder is part of the scan.
    private func trashIndex(in catalog: MapCatalog, for folder: String?) -> Int? {
        folder.flatMap { catalog.tree.nearestIndex(toPath: catalog.treePath(forUserPath: $0)) }
    }

    /// Asks, then carries out a cleanup suggestion in the background.
    func clean(_ item: CleanupItem) {
        guard cleaning == nil, canNavigate else { return }
        let alert = NSAlert()
        switch item.rule.action {
        case .emptyTrash:
            alert.messageText = String(localized: "清空废纸篓？")
            alert.informativeText = String(localized: "里面约 \(Format.size(item.size)) 的东西会被永久删除，不能撤销。") + snapshotNote
            alert.addButton(withTitle: String(localized: "清空废纸篓"))
        case .trashContents:
            alert.messageText = String(localized: "把“\(item.rule.name)”移到废纸篓？")
            alert.informativeText = String(localized: "约 \(Format.size(item.size))，\(item.rule.note)。清空废纸篓之后，空间才会腾出来。") + snapshotNote
            alert.addButton(withTitle: String(localized: "移到废纸篓"))
        }
        alert.addButton(withTitle: String(localized: "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        cleaning = item.id
        let startedOn = target
        Task.detached(priority: .userInitiated) {
            let outcome = item.perform()
            await MainActor.run { self.finishCleaning(item, outcome, on: startedOn) }
        }
    }

    private func finishCleaning(_ item: CleanupItem, _ outcome: CleanupItem.Outcome, on startedOn: ScanTarget) {
        cleaning = nil
        // Another disk may be on screen by now; its map has nothing to do with this.
        guard let catalog, target == startedOn, !catalog.isLive else { return }
        var tree = catalog.tree
        let destination = item.rule.action == .trashContents ? trashIndex(in: catalog, for: outcome.trashFolder) : nil
        item.record(outcome, in: &tree, catalog: catalog, trash: destination)
        apply(tree)

        if outcome.failures > 0 {
            let alert = NSAlert()
            alert.messageText = String(localized: "有 \(outcome.failures) 项没能清理")
            alert.informativeText = String(localized: "它们可能正在使用，或受系统保护。其余的已经清理好了。")
            alert.runModal()
        }
    }

    /// Puts an edited tree on screen and saves it.
    private func apply(_ tree: FileTree) {
        catalog = MapCatalog(tree: tree, volume: target.volume)
        while focus != FileTree.root, tree.nodes[focus].size == 0 || tree.nodes[focus].removed {
            focus = Int(tree.nodes[focus].parent)
        }
        shownFocus = focus
        rebuild(.update)
        updateCleanup()
        refreshDisks()
        if cacheOverride == nil {
            let url = ScanStore.url(for: target)
            Task.detached(priority: .utility) { ScanStore.save(tree, to: url) }
        }
    }

    // MARK: For still pictures

    /// Puts a scan on screen without touching the disk or the saved settings.
    func present(_ tree: FileTree, mode: MapMode, theme: Theme, focus: Int, mapSize: CGSize,
                 live: ScanStatus? = nil) {
        self.mode = mode
        self.theme = theme
        catalog = MapCatalog(tree: tree, volume: volumeOverride ?? target.volume, isLive: live != nil)
        scan = live
        self.focus = focus
        shownFocus = focus
        self.mapSize = mapSize
        phase = .ready
        updateCleanup()
        refreshDisks()
        rebuildNow()
        motion.settle()
    }

    /// Replaces the list of disks, to picture a Mac with made-up ones.
    func presentDisks(_ list: [DiskSummary]) {
        disks = list
    }

    /// Switches to the other view and stops the picture `seconds` into the change.
    func presentSwap(to newMode: MapMode, after seconds: Double) {
        guard let catalog else { return }
        let start = Date()
        mode = newMode
        generation += 1
        install(MapScene.build(newMode, catalog: catalog, focus: focus, size: mapSize), change: .swap)
        _ = motion.advance(to: start)
        _ = motion.advance(to: start.addingTimeInterval(seconds))
    }

    /// Starts going into (or up to) a folder and stops the picture `seconds` into the move.
    func presentMove(to index: Int, after seconds: Double) {
        guard let catalog else { return }
        focus = index
        let start = Date()
        install(MapScene.build(mode, catalog: catalog, focus: index, size: mapSize), change: .navigate)
        _ = motion.advance(to: start)
        _ = motion.advance(to: start.addingTimeInterval(seconds))
    }

    func presentAccessRequest() {
        phase = .needsAccess
    }
}
