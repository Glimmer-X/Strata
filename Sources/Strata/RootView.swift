import ScanCore
import SwiftUI

/// The window: the side panel and the map, or what stands in for them before a scan exists.
struct RootView: View {
    @ObservedObject var model: AppModel
    var live = true

    var body: some View {
        let theme = model.theme
        ZStack(alignment: .topLeading) {
            theme.background.color.ignoresSafeArea()
            switch model.phase {
            case .checking:
                EmptyView()
            case .needsAccess:
                AccessView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if let catalog = model.catalog {
                    HStack(spacing: 0) {
                        SidePanel(model: model, catalog: catalog).frame(width: Metrics.panelWidth)
                        MapArea(model: model, live: live)
                    }
                }
            }
            if let menu = model.menu, model.phase == .ready {
                // A click anywhere else closes the menu.
                Color.black.opacity(0.001)
                    .onTapGesture { model.show(menu: nil) }
                switch menu {
                case .disks:
                    DiskPicker(model: model)
                        .offset(x: 18, y: 96)
                        .transition(.scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity))
                case .settings:
                    SettingsMenu(model: model)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 14).padding(.top, 48)
                        .transition(.scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity))
                }
            }
        }
        .foregroundStyle(theme.text.color)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .ignoresSafeArea()
    }
}

private struct MapArea: View {
    @ObservedObject var model: AppModel
    let live: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                if let parent = parentName {
                    BackButton(model: model, parent: parent)
                        .transition(.scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
                }
                Spacer()
                ModeSwitch(model: model)
                ThemeDots(model: model)
                GearButton(model: model)
            }
            .frame(height: Metrics.barHeight)
            .padding(.leading, Metrics.mapInsets.leading)
            .padding(.trailing, Metrics.mapInsets.trailing - 6)

            ZStack(alignment: .topLeading) {
                MapCanvas(model: model, live: live)
                HoverCard(pointer: model.pointer, theme: model.theme, bounds: model.mapSize)
            }
            .padding(Metrics.mapInsets)
        }
    }

    /// The folder one level up, while inside a folder.
    private var parentName: String? {
        guard let catalog = model.catalog, model.focus != FileTree.root, model.canNavigate else { return nil }
        return catalog.crumbs(to: model.focus).dropLast().last?.name
    }
}

/// Chooses between the two ways of drawing the same folder.
private struct ModeSwitch: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let theme = model.theme
        HStack(spacing: 2) {
            ForEach(MapMode.allCases, id: \.self) { mode in
                Button { model.mode = mode } label: {
                    Text(mode == .bubbles ? LocalizedStringKey("气泡") : LocalizedStringKey("流动"))
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .foregroundStyle(model.mode == mode ? theme.text.color : theme.secondaryText.color)
                        .background(theme.line.color.opacity(model.mode == mode ? 0.14 : 0), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(theme.line.color.opacity(0.06), in: Capsule())
    }
}

/// One dot per colour scheme.
private struct ThemeDots: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 9) {
            ForEach(Theme.all) { theme in
                Button { model.theme = theme } label: {
                    Circle()
                        .fill(LinearGradient(colors: [theme.tones[0].color, theme.tones[1].color],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 15, height: 15)
                        .overlay(Circle().strokeBorder(model.theme.text.color.opacity(model.theme == theme ? 0.9 : 0), lineWidth: 1.5).padding(-3.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(theme.name)
            }
        }
    }
}

/// Shown before the first scan when macOS would keep most folders from being read.
private struct AccessView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 14) {
            Text("先打开“完全磁盘访问权限”").font(.system(size: 26, weight: .semibold))
            Text("没有它，大部分文件夹都看不到。Strata 只读名字和大小，不打开文件内容。")
                .font(.system(size: 14)).lineSpacing(3)
                .foregroundStyle(theme.secondaryText.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("打开系统设置") { model.openAccessSettings() }
                    .buttonStyle(PillButton(theme: theme, filled: true))
                Button("已经打开了") { model.accessGranted() }
                    .buttonStyle(PillButton(theme: theme, filled: false))
            }
            .padding(.top, 8)
        }
        .frame(width: 420, alignment: .leading)
    }
}

struct PillButton: ButtonStyle {
    let theme: Theme
    let filled: Bool
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .padding(.horizontal, compact ? 11 : 16).padding(.vertical, compact ? 5 : 8)
            .foregroundStyle(filled ? theme.background.color : theme.text.color)
            .background(filled ? theme.text.color : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.text.color.opacity(filled ? 0 : 0.5)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Goes up one folder; shown above the map while inside a folder.
private struct BackButton: View {
    @ObservedObject var model: AppModel
    let parent: String
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        Button { model.goUp() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    .offset(x: hovering ? -2 : 0)
                Text(parent).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(hovering ? theme.text.color : theme.secondaryText.color)
            .padding(.leading, 12).padding(.trailing, 15).padding(.vertical, 8)
            .background(theme.line.color.opacity(hovering ? 0.12 : 0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 260, alignment: .leading)
        .fixedSize()
        .scaleEffect(hovering ? 1.03 : 1, anchor: .leading)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: hovering)
        .help("回到上一层（Esc）")
    }
}

/// Opens the settings.
private struct GearButton: View {
    @ObservedObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        let open = model.menu == .settings
        Button { model.show(menu: .settings) } label: {
            Image(systemName: "gearshape").font(.system(size: 14, weight: .medium))
                .foregroundStyle(hovering || open ? theme.text.color : theme.secondaryText.color)
                .rotationEffect(.degrees(hovering || open ? 40 : 0))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: hovering || open)
        .help("设置")
    }
}
