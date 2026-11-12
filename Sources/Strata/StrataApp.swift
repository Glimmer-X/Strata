import AppKit
import SwiftUI

struct StrataApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel = {
        let model = AppModel()
        model.cacheOverride = StrataApp.cacheOverride
        return model
    }()

    /// `--cache FILE` shows a saved scan from somewhere else, for trying the app during
    /// development without scanning.
    private static var cacheOverride: URL? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--cache"), flag + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[flag + 1])
    }

    var body: some Scene {
        Window("Strata", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1040, minHeight: 660)
                .onAppear { model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.show(menu: .settings) }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("回到上一层") { model.goUp() }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("重新扫描") { model.beginScan() }.keyboardShortcut("r", modifiers: .command)
                Button("选择文件夹…") { model.chooseFolder() }.keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary is run outside its bundle during development.
        NSApp.setActivationPolicy(.regular)
        // A traced run is a development check: let it appear without taking the keyboard.
        if ProcessInfo.processInfo.environment["STRATA_TRACE"] == nil { NSApp.activate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
