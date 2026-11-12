import SwiftUI

/// The menu under the name at the top of the panel: the disks of this Mac, the folder being
/// looked at if it is one, and a way to choose a folder.
struct DiskPicker: View {
    @ObservedObject var model: AppModel

    static let width: CGFloat = 300

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.disks) { disk in
                PickerRow(theme: theme, isCurrent: disk.target == model.target, action: { model.select(disk.target) }) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(disk.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text("可用 \(Format.size(disk.available))").font(.system(size: 11.5)).monospacedDigit()
                                .foregroundStyle(theme.secondaryText.color)
                        }
                        UsageBar(share: disk.usedShare, fill: theme.tones[2].color, outline: theme.line.color.opacity(0.32))
                    }
                }
            }
            if !model.target.isVolume {
                PickerRow(theme: theme, isCurrent: true, action: { model.show(menu: nil) }) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.target.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                        Text(model.target.path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(theme.secondaryText.color)
                    }
                }
            }
            Rectangle().fill(theme.line.color.opacity(0.12)).frame(height: 1)
                .padding(.vertical, 4).padding(.horizontal, 10)
            PickerRow(theme: theme, isCurrent: false, action: {
                model.show(menu: nil)
                model.chooseFolder()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText.color)
                    Text("选择文件夹…").font(.system(size: 13.5))
                    Spacer()
                    Text("⌘O").font(.system(size: 11.5)).foregroundStyle(theme.secondaryText.color)
                }
            }
        }
        .padding(6)
        .frame(width: Self.width)
        .menuCard(theme)
    }
}

/// The settings, under the gear above the map.
struct SettingsMenu: View {
    @ObservedObject var model: AppModel

    static let width: CGFloat = 260

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 2) {
            Text("语言").font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText.color)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
            ForEach(AppLanguage.allCases) { language in
                PickerRow(theme: theme, isCurrent: model.language == language, action: { model.choose(language) }) {
                    if let name = language.nativeName {
                        Text(verbatim: name).font(.system(size: 13.5))
                    } else {
                        Text("跟随系统").font(.system(size: 13.5))
                    }
                }
            }
            if model.languageNeedsRelaunch {
                Rectangle().fill(theme.line.color.opacity(0.12)).frame(height: 1)
                    .padding(.vertical, 4).padding(.horizontal, 10)
                HStack(spacing: 8) {
                    Text("重新打开后生效").font(.system(size: 12)).foregroundStyle(theme.secondaryText.color)
                    Spacer(minLength: 6)
                    Button("现在重新打开") { model.relaunch() }
                        .buttonStyle(PillButton(theme: theme, filled: true, compact: true))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .transition(.opacity)
            }
        }
        .padding(6)
        .frame(width: Self.width, alignment: .leading)
        .menuCard(theme)
        .animation(.easeOut(duration: 0.18), value: model.languageNeedsRelaunch)
    }
}

extension View {
    /// The look of a menu floating over the window.
    func menuCard(_ theme: Theme) -> some View {
        background(theme.background.lighter(theme.isDark ? 0.06 : 0.035).color,
                   in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.line.color.opacity(0.16)))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.14), radius: 18, y: 8)
    }
}

/// One choice in a menu. The current one is marked; the one under the pointer lights up.
private struct PickerRow<Content: View>: View {
    let theme: Theme
    let isCurrent: Bool
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold))
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: 12)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(theme.line.color.opacity(hovering ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
