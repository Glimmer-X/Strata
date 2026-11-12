import AppKit

/// The language the app speaks: the system's, or one chosen in the settings.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    /// Each language is listed in itself, so anyone can find their own.
    var nativeName: String? {
        switch self {
        case .system: return nil
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }

    private static let key = "AppleLanguages"

    /// The choice saved for this app. macOS reads it when the app starts, which is why a
    /// change shows after the app is opened again.
    static var saved: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
              let first = list.first else { return .system }
        return AppLanguage(rawValue: first) ?? .system
    }

    func save() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.key)
        }
    }

    /// Quits and opens the app again, once this copy has gone.
    @MainActor static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"",
                             Bundle.main.bundlePath]
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}
