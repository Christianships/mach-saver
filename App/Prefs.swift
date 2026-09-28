import Foundation

enum KeepAwake: String, CaseIterable {
    case automatic, always, off

    var title: String {
        switch self {
        case .automatic: "While Agents Run"
        case .always: "Always"
        case .off: "Off"
        }
    }
}

/// Settings live in `defaults read com.christianaguilar.mach-saver`.
enum Prefs {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            "keepAwake": KeepAwake.automatic.rawValue,
            "idleMinutes": 2.0,
            "screensaver": "afterburner",
            // Process names that count as an agent session.
            "agentNames": ["claude", "codex", "gemini", "opencode", "aider", "cursor-agent", "amp", "goose", "crush", "qwen"],
        ])
    }

    static var keepAwake: KeepAwake {
        get { KeepAwake(rawValue: d.string(forKey: "keepAwake") ?? "") ?? .automatic }
        set { d.set(newValue.rawValue, forKey: "keepAwake") }
    }

    /// Minutes of no input before the screensaver shows. 0 turns it off.
    static var idleMinutes: Double {
        get { d.double(forKey: "idleMinutes") }
        set { d.set(newValue, forKey: "idleMinutes") }
    }

    /// Id of the active screensaver.
    static var screensaver: String {
        get { d.string(forKey: "screensaver") ?? "afterburner" }
        set { d.set(newValue, forKey: "screensaver") }
    }

    static var agentNames: [String] { d.stringArray(forKey: "agentNames") ?? [] }
}
