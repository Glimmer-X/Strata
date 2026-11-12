import ScanCore
import SwiftUI

/// The column beside the map: what is being looked at, how full it is, and what is largest
/// or safe to clean.
struct SidePanel: View {
    @ObservedObject var model: AppModel
    let catalog: MapCatalog

    private var theme: Theme { model.theme }
    private var atTop: Bool { model.focus == FileTree.root }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // What is being looked at; fades over when that changes.
            VStack(alignment: .leading, spacing: 0) {
                if !atTop {
                    folderHeader
                } else if catalog.volume != nil {
                    diskHeader
                } else {
                    scannedFolderHeader
                }
                sectionTitle.padding(.top, 26).padding(.bottom, 6)
                GeometryReader { geometry in
                    if model.panelTab == .cleanup, atTop, !model.cleanup.isEmpty {
                        cleanupList(rows: Int(geometry.size.height / CleanupRow.height))
                    } else {
                        list(catalog.items(in: model.focus), rows: Int(geometry.size.height / ItemRow.height))
                    }
                }
            }
            .id(model.target.path + "#\(model.focus)")
            .transition(.opacity)

            if model.disks.count > 1 {
                DiskList(model: model).padding(.top, 14)
            }
            footer.padding(.top, 16)
        }
        .padding(.leading, 28).padding(.trailing, 16).padding(.top, 58).padding(.bottom, 22)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Headers

    /// The disk or folder being looked at; opens the menu to look at another one.
    private var targetName: some View {
        TargetName(model: model, name: catalog.volume?.name ?? model.target.name)
    }

    /// While the first scan runs: how far it has got.
    @ViewBuilder private var scanLine: some View {
        if let scan = model.scan, scan.isFirst {
            Text("正在扫描 · 已经看过 \(Format.count(Int(scan.entries))) 项")
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(theme.secondaryText.color)
                .padding(.top, 6)
        }
    }

    /// The disk at a glance: a bar split into files, the rest in use, and free space, with
    /// the three figures under it.
    private var diskHeader: some View {
        let files = catalog.tree.nodes[FileTree.root].size
        let hidden = catalog.hiddenBytes
        let free = catalog.volume?.availableBytes ?? 0
        let solid = theme.tones[2].color
        let muted = theme.hidden.lighter(theme.isDark ? 0.07 : -0.08).color
        let scanning = catalog.isLive
        return VStack(alignment: .leading, spacing: 0) {
            targetName
            scanLine
            CapacityBar(parts: [(files, solid), (hidden, muted), (free, nil)], outline: theme.line.color.opacity(0.42))
                .padding(.top, 18)
            HStack(alignment: .top, spacing: 0) {
                figure(scanning ? "已扫到" : "文件", Format.size(files), swatch: solid)
                figure(scanning ? "还没扫到" : catalog.isStartupDisk ? "快照与系统" : "读不到的部分",
                       Format.size(hidden), swatch: muted)
                figure("可用", Format.size(free), swatch: nil)
            }
            .padding(.top, 13)
        }
    }

    /// A single folder was scanned: there is no disk to compare with.
    private var scannedFolderHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            targetName
            Text(catalog.tree.rootPath).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(theme.secondaryText.color).padding(.top, 6)
            scanLine
            HStack(alignment: .top, spacing: 0) {
                figure("大小", Format.size(catalog.tree.nodes[FileTree.root].size), swatch: theme.tones[2].color)
                if !catalog.isLive {
                    figure("文件和文件夹", Format.count(catalog.tree.entryCount), swatch: nil, outlined: false)
                }
            }
            .padding(.top, 18)
        }
    }

    private var folderHeader: some View {
        let crumbs = catalog.crumbs(to: model.focus)
        let node = catalog.tree.nodes[model.focus]
        let total = max(catalog.totalBytes, 1)
        let solid = theme.tones[2].color
        return VStack(alignment: .leading, spacing: 0) {
            // The way back: the nearest folders above this one.
            HStack(spacing: 5) {
                ForEach(Array(crumbs.dropLast().suffix(3)), id: \.index) { crumb in
                    Button(crumb.name) { model.go(to: crumb.index) }
                        .buttonStyle(.plain).lineLimit(1)
                    Text("›")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.secondaryText.color)
            Text(crumbs.last?.name ?? "")
                .font(.system(size: 24, weight: .semibold)).lineLimit(2)
                .padding(.top, 8)
            CapacityBar(parts: [(node.size, solid), (total - min(node.size, total), nil)], outline: theme.line.color.opacity(0.42))
                .padding(.top, 18)
            HStack(alignment: .top, spacing: 0) {
                figure("大小", Format.size(node.size), swatch: solid)
                figure(catalog.volume == nil ? "占整个文件夹" : "占整块磁盘", Format.percent(Double(node.size) / Double(total)), swatch: nil)
            }
            .padding(.top, 13)
        }
    }

    /// One labelled number; the swatch ties it to its part of the bar.
    private func figure(_ label: LocalizedStringKey, _ value: String, swatch: Color?, outlined: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if swatch != nil || outlined {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(swatch ?? .clear)
                        .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(theme.line.color.opacity(swatch == nil ? 0.55 : 0), lineWidth: 1))
                        .frame(width: 8, height: 8)
                }
                Text(label).font(.system(size: 11.5)).foregroundStyle(theme.secondaryText.color).lineLimit(1)
            }
            Text(value).font(.system(size: 17, weight: .medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Lists

    /// "Largest", or a choice between it and the cleanup suggestions at the top of the disk.
    @ViewBuilder private var sectionTitle: some View {
        if atTop, !model.cleanup.isEmpty {
            HStack(spacing: 16) {
                tab("最大的", .largest)
                tab("可以清理", .cleanup)
            }
        } else {
            Text(atTop ? "最大的" : "里面最大的")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText.color)
        }
    }

    private func tab(_ title: LocalizedStringKey, _ tab: AppModel.PanelTab) -> some View {
        Button { model.panelTab = tab } label: {
            Text(title)
                .font(.system(size: 12, weight: model.panelTab == tab ? .semibold : .medium))
                .foregroundStyle(model.panelTab == tab ? theme.text.color : theme.secondaryText.color)
        }
        .buttonStyle(.plain)
    }

    private func list(_ items: [MapItem], rows: Int) -> some View {
        let shown = items.filter { $0.kind != .free }.prefix(max(1, min(9, rows)))
        return VStack(spacing: 0) {
            ForEach(Array(shown)) { item in
                ItemRow(model: model, item: item, swatch: swatch(for: item), isOn: model.highlighted == item.id)
                divider
            }
        }
    }

    private func cleanupList(rows: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(model.cleanup.prefix(max(1, rows)))) { item in
                CleanupRow(model: model, item: item)
                divider
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(theme.line.color.opacity(0.1)).frame(height: 1)
    }

    /// The colour the item has on the map, so list and map can be matched at a glance.
    private func swatch(for item: MapItem) -> Color {
        theme.fill(model.scene?.tone(ofTopItem: item.id) ?? Tone(role: .neutral)).color
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            if let scan = model.scan {
                if scan.isFirst {
                    Text("正在扫描…")
                } else {
                    Text("正在更新")
                    if let fraction = scan.fraction { Text(Format.percent(fraction)).monospacedDigit() }
                }
            } else {
                Text(Format.scanned(catalog.tree.scannedAt))
                Button("重新扫描") { model.beginScan() }
                    .buttonStyle(.plain).underline()
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.secondaryText.color)
    }
}

private struct ItemRow: View {
    /// Height of a row with its divider, for working out how many fit.
    static let height: CGFloat = 36.5

    @ObservedObject var model: AppModel
    let item: MapItem
    let swatch: Color
    let isOn: Bool
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(swatch).frame(width: 11, height: 11)
            Text(item.title).font(.system(size: 13.5)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if hovering, item.isEntry, model.canNavigate {
                Button { model.reveal(item) } label: { Image(systemName: "magnifyingglass") }
                    .help("在访达中显示")
                Button { model.trash(item) } label: { Image(systemName: "trash") }
                    .help("移到废纸篓")
            }
            Text(Format.size(item.size)).font(.system(size: 13)).monospacedDigit()
                .foregroundStyle(theme.secondaryText.color)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 9).padding(.horizontal, 8)
        .background(theme.line.color.opacity(isOn ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            model.listHover(inside ? item : nil)
        }
        .onTapGesture { model.open(item) }
    }
}

/// One cleanup suggestion: what it is, why it can go, and how much it frees.
private struct CleanupRow: View {
    static let height: CGFloat = 51

    @ObservedObject var model: AppModel
    let item: CleanupItem
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        let busy = model.cleaning == item.id
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.rule.name).font(.system(size: 13.5)).lineLimit(1)
                Text(item.rule.note).font(.system(size: 11.5)).lineLimit(1)
                    .foregroundStyle(theme.secondaryText.color)
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.small)
            } else if hovering, model.cleaning == nil, let first = item.folders.first {
                Button { model.revealInFinder(first) } label: { Image(systemName: "magnifyingglass") }
                    .help("在访达中显示")
                Button { model.clean(item) } label: { Image(systemName: "trash") }
                    .help(item.rule.action == .emptyTrash ? "清空废纸篓" : "移到废纸篓")
            }
            Text(Format.size(item.size)).font(.system(size: 13)).monospacedDigit()
                .foregroundStyle(theme.secondaryText.color)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8).padding(.horizontal, 8)
        .background(theme.line.color.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if let first = item.folders.first { model.reveal(inMap: first) } }
    }
}

/// The name of the disk or folder at the top of the panel, which opens the disk menu.
private struct TargetName: View {
    @ObservedObject var model: AppModel
    let name: String
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        let open = model.menu == .disks
        Button { model.show(menu: .disks) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(name).font(.system(size: 24, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.secondaryText.color)
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .offset(y: hovering && !open ? 1.5 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovering)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: open)
        .help("看另一块磁盘或一个文件夹")
    }
}

/// The disks of this Mac, at the bottom of the panel when there is more than one.
private struct DiskList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("磁盘").font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.theme.secondaryText.color)
                .padding(.bottom, 2)
            ForEach(model.disks) { disk in
                DiskRow(model: model, disk: disk, isCurrent: disk.target == model.target)
            }
        }
    }
}

private struct DiskRow: View {
    @ObservedObject var model: AppModel
    let disk: DiskSummary
    let isCurrent: Bool
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        let lit = isCurrent || hovering
        Button { model.select(disk.target) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(disk.name).font(.system(size: 13, weight: isCurrent ? .semibold : .regular)).lineLimit(1)
                        .foregroundStyle(lit ? theme.text.color : theme.secondaryText.color)
                    Spacer(minLength: 6)
                    Text("可用 \(Format.size(disk.available))").font(.system(size: 11.5)).monospacedDigit()
                        .foregroundStyle(theme.secondaryText.color)
                }
                UsageBar(share: disk.usedShare, fill: lit ? theme.tones[2].color : theme.line.color.opacity(0.32),
                         outline: theme.line.color.opacity(0.32))
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(theme.line.color.opacity(isCurrent ? 0.08 : hovering ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering && !isCurrent ? 1.025 : 1)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: hovering)
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
    }
}

/// How full a disk is: a filled part, then an outline for what is free.
struct UsageBar: View {
    let share: Double
    let fill: Color
    let outline: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let used = max(3, min(width - 6, width * share))
            HStack(spacing: 2) {
                Capsule().fill(fill).frame(width: used)
                Capsule().strokeBorder(outline, lineWidth: 1)
            }
        }
        .frame(height: 5)
    }
}

/// A thin bar split in proportion. A part without a colour is drawn as an empty outline.
private struct CapacityBar: View {
    let parts: [(size: UInt64, color: Color?)]
    let outline: Color

    var body: some View {
        GeometryReader { geometry in
            let shown = parts.filter { $0.size > 0 }
            let total = Double(shown.reduce(0) { $0 + $1.size })
            let usable = geometry.size.width - 3 * CGFloat(max(shown.count - 1, 0))
            HStack(spacing: 3) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, part in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(part.color ?? .clear)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(outline.opacity(part.color == nil ? 1 : 0), lineWidth: 1))
                        .frame(width: max(4, usable * CGFloat(Double(part.size) / max(total, 1))))
                }
            }
        }
        .frame(height: 10)
    }
}
