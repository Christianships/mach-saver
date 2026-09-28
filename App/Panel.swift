import AppKit
import ServiceManagement
import SwiftUI

// MARK: messages between the agent and the panel

/// The panel is its own process (see MachSaverPanel), so it and the menu bar
/// agent talk through distributed notifications: the agent broadcasts what
/// it's doing, the panel asks for that on open and sends commands back.
enum Bus {
    static let status = Notification.Name("dev.mach-saver.status")
    static let request = Notification.Name("dev.mach-saver.status.request")
    static let command = Notification.Name("dev.mach-saver.command")

    static func post(_ name: Notification.Name, _ info: [String: Any]? = nil) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
    }

    static func observe(_ name: Notification.Name, _ handler: @escaping ([AnyHashable: Any]) -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { handler($0.userInfo ?? [:]) }
    }
}

// MARK: model

final class PanelModel: ObservableObject {
    enum Tab: String, CaseIterable { case home = "Home", screensaver = "Screensaver", agents = "Agents", settings = "Settings" }
    @Published var tab: Tab = .home

    // From the agent.
    @Published var agents: [String] = []
    @Published var working = false
    @Published var awake = false
    @Published var session = false
    @Published var heard = false

    // Settings, read and written straight through to the shared defaults.
    @Published var keepAwake = Prefs.keepAwake
    @Published var idleMinutes = Prefs.idleMinutes
    @Published var palette = Afterburner.Settings.palette
    @Published var agentNames = Prefs.agentNames
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var thumbnails: [String: NSImage] = [:]

    init() {
        Bus.observe(Bus.status) { [weak self] info in
            guard let self else { return }
            agents = info["agents"] as? [String] ?? []
            working = info["working"] as? Bool ?? false
            awake = info["awake"] as? Bool ?? false
            session = info["session"] as? Bool ?? false
            heard = true
        }
        Bus.post(Bus.request)
        // Previews render once, off the first frame, so the panel opens instantly.
        DispatchQueue.main.async { [weak self] in self?.renderThumbnails() }
    }

    var agentSummary: String {
        let counts = Dictionary(agents.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.sorted { $0.key < $1.key }.map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }.joined(separator: ", ")
    }

    // MARK: actions

    func showScreensaver() {
        Bus.post(Bus.command, ["do": "show"])
        MachSaverPanel.close()
    }

    func lock() {
        MachSaverPanel.close()
        ScreenLock.lockNow()
    }

    func setKeepAwake(_ m: KeepAwake) { keepAwake = m; Prefs.keepAwake = m; changed() }
    func setIdle(_ m: Double) { idleMinutes = m; Prefs.idleMinutes = m; changed() }
    func setPalette(_ name: String) { palette = name; Afterburner.Settings.palette = name }

    func addAgent(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !agentNames.contains(name) else { return }
        agentNames.append(name); Prefs.agentNames = agentNames; changed()
    }
    func removeAgent(_ name: String) { agentNames.removeAll { $0 == name }; Prefs.agentNames = agentNames; changed() }
    func resetAgents() { Prefs.resetAgentNames(); agentNames = Prefs.agentNames; changed() }

    func setLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSSound.beep() }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Tells the agent to re-read settings now rather than on its next tick.
    private func changed() { Bus.post(Bus.command, ["do": "refresh"]) }

    /// A still of each colour, rendered off screen at the main screen's
    /// proportions and scaled down.
    private func renderThumbnails() {
        let screen = NSScreen.main?.frame.size ?? NSSize(width: 1512, height: 982)
        let logo = Afterburner.Settings.loadLogo()
        for p in Palette.all {
            let view = Afterburner(frame: NSRect(origin: .zero, size: screen), palette: p, logo: logo)
            for _ in 0..<120 { view.advance(1.0 / 30) }     // 4s in: the jet has landed, MACH is at rest
            // Render at full size (the scene lays itself out for the screen), then shrink.
            guard let full = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: full)
            let size = NSSize(width: 520, height: 520 * screen.height / screen.width)
            thumbnails[p.name] = NSImage(size: size, flipped: false) { r in full.draw(in: r); return true }
        }
    }
}

// MARK: panel

/// A floating HUD centred on the screen the pointer is on, like Spotlight.
/// Esc or clicking elsewhere dismisses it.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func resignKey() {
        super.resignKey()
        if NSApp.modalWindow == nil { close() }
    }
}

/// Like MouseSkins, the panel runs in its own short-lived process
/// (`MachSaver --panel`, started from the menu bar) and quits when it closes,
/// so the agent that sits in the menu bar all day never loads SwiftUI.
enum MachSaverPanel {
    static let size = NSSize(width: 600, height: 460)
    private static var panel: FloatingPanel?

    static func show() {
        let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(b)?.isHidden = true
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        let host = NSHostingView(rootView: PanelView().environmentObject(PanelModel()).tint(Accent.color))
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        p.contentView = blur
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        panel = p

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    static func close() { panel?.close() }
}

/// Starts and stops the panel process from the menu bar agent.
enum PanelProcess {
    private static var process: Process?

    static func toggle() {
        if let p = process, p.isRunning { p.terminate(); process = nil; return }
        let p = Process()
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["--panel"]
        do { try p.run(); process = p } catch { NSSound.beep() }
    }
}

enum Accent {
    static let color = Color(red: 0.66, green: 0.33, blue: 0.97)     // #A855F7, MACH's violet
}

// MARK: shell

struct PanelView: View {
    @EnvironmentObject var model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $model.tab) {
                    ForEach(PanelModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 340)
                Spacer()
                toolbar
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)

            Group {
                switch model.tab {
                case .home: HomeView()
                case .screensaver: ScreensaverTab()
                case .agents: AgentsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()      // the hidden title bar would otherwise leave a gap on top
    }

    @ViewBuilder private var toolbar: some View {
        switch model.tab {
        case .home, .screensaver:
            IconButton("lock", "Lock screen") { model.lock() }
            IconButton("play.fill", "Show the screensaver now", tint: Accent.color, filled: true) { model.showScreensaver() }
        case .agents:
            IconButton("arrow.counterclockwise", "Reset to the built-in agent list") { model.resetAgents() }
        case .settings:
            IconButton("lock", "Lock screen") { model.lock() }
        }
    }
}

struct IconButton: View {
    let symbol: String, help: String
    var tint: Color? = nil
    var filled = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    init(_ symbol: String, _ help: String, tint: Color? = nil, filled: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol; self.help = help; self.tint = tint; self.filled = filled; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(filled ? Color.white : tint ?? Color.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(filled ? AnyShapeStyle(tint ?? .accentColor) : AnyShapeStyle(Color.primary.opacity(0.08))))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct Badge: View {
    let text: String, color: Color
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(color))
    }
}

/// A rounded card, the panel's basic surface.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
    }
}

private struct Thumbnail: View {
    let image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { ProgressView().controlSize(.small) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: home

struct HomeView: View {
    @EnvironmentObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.awake ? "Keeping your Mac awake" : "Your Mac sleeps as usual")
                            .font(.system(size: 17, weight: .bold)).lineLimit(1)
                        if model.session { Badge(text: "Session", color: Accent.color, symbol: "play.fill") }
                        if !model.agents.isEmpty {
                            Badge(text: model.working ? "Working" : "Idle", color: model.working ? .green : .gray,
                                  symbol: model.working ? "bolt.fill" : "moon.fill")
                        }
                    }
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.horizontal, 16)

            HStack(spacing: 10) {
                stat("Agents", model.agents.isEmpty ? "None" : "\(model.agents.count) running", "terminal")
                stat("Keep awake", model.keepAwake.title, "cup.and.saucer")
                stat("Screensaver", model.idleMinutes == 0 ? "Never" : "After \(Int(model.idleMinutes)) min", "timer")
            }
            .padding(.horizontal, 16)

            Button { model.showScreensaver() } label: {
                Thumbnail(image: model.thumbnails[model.palette])
                    .overlay(alignment: .bottomTrailing) {
                        Label("Show now", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Accent.color)).padding(10)
                    }
            }
            .buttonStyle(.plain)
            .help("Show the screensaver now")
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
    }

    private var summary: String {
        guard model.heard else { return "Waiting for the menu bar agent…" }
        if model.session { return "The screensaver is up until you come back." }
        if model.agents.isEmpty { return "No agents running. Open Mach Saver or press play to show the screensaver." }
        return model.working
            ? "\(model.agentSummary) working. The screensaver comes up after \(Int(model.idleMinutes)) min away."
            : "\(model.agentSummary) open but idle, so your Mac can sleep."
    }

    private func stat(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Accent.color).frame(height: 22)
            Text(value).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: screensaver

struct ScreensaverTab: View {
    @EnvironmentObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Palette.all, id: \.name) { p in
                        tile(p)
                            .onTapGesture { model.setPalette(p.name) }
                            .onTapGesture(count: 2) { model.setPalette(p.name); model.showScreensaver() }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 2)
            }
            .frame(height: 96)

            Card {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Afterburner").font(.system(size: 17, weight: .bold))
                        Badge(text: Palette.named(model.palette).title, color: Accent.color, symbol: "paintpalette.fill")
                    }
                    Text("MACH over the jet, playing one of \(TextEffects.Kind.allCases.count) text effects after another, like Omarchy's screensaver.")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.horizontal, 16)

            Thumbnail(image: model.thumbnails[model.palette])
                .padding(.horizontal, 16)
            Text("Click a colour to use it · double-click to show it now")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    private func tile(_ p: Palette) -> some View {
        let selected = model.palette == p.name
        return VStack(spacing: 6) {
            Thumbnail(image: model.thumbnails[p.name]).frame(width: 96, height: 60)
            HStack(spacing: 4) {
                if selected { Circle().fill(.green).frame(width: 6, height: 6) }
                Text(p.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
        }
        .padding(6)
        .frame(width: 112, height: 90)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(selected ? 0.12 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Accent.color.opacity(0.9) : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: agents

struct AgentsView: View {
    @EnvironmentObject var model: PanelModel
    @State private var draft = ""
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agents").font(.system(size: 17, weight: .bold))
                    Text("Programs that count as an agent. One counts as working while it and what it started use 4% or more of a core.")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.horizontal, 16)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.agentNames, id: \.self) { name in
                        let running = model.agents.filter { $0 == name }.count
                        HStack(spacing: 6) {
                            Circle().fill(running > 0 ? (model.working ? Color.green : Color.gray) : Color.primary.opacity(0.15))
                                .frame(width: 7, height: 7)
                            Text(name).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                            if running > 1 { Text("×\(running)").font(.system(size: 10)).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                            Button { model.removeAgent(name) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain).help("Remove \(name)")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                    }
                }
                .padding(.horizontal, 16)
            }

            HStack(spacing: 8) {
                TextField("Add a program name, e.g. claude", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.addAgent(draft); draft = "" }
                IconButton("plus", "Add", tint: Accent.color, filled: true) { model.addAgent(draft); draft = "" }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
    }
}

// MARK: settings

struct SettingsView: View {
    @EnvironmentObject var model: PanelModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                group("Keep awake") {
                    row("Stay awake", "While agents work, always, or never (the screensaver still keeps the display on)") {
                        Picker("", selection: Binding(get: { model.keepAwake }, set: { model.setKeepAwake($0) })) {
                            ForEach(KeepAwake.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu).frame(width: 170)
                    }
                }
                group("Screensaver") {
                    row("Show after", "Minutes with no keyboard or mouse input while agents work") {
                        Picker("", selection: Binding(get: { model.idleMinutes }, set: { model.setIdle($0) })) {
                            ForEach([1.0, 2, 5, 10, 15, 0], id: \.self) { m in Text(m == 0 ? "Never" : "\(Int(m)) min").tag(m) }
                        }
                        .pickerStyle(.menu).frame(width: 110)
                    }
                    Divider().opacity(0.4)
                    row("Colour", "Also on the Screensaver tab") {
                        Picker("", selection: Binding(get: { model.palette }, set: { model.setPalette($0) })) {
                            ForEach(Palette.all, id: \.name) { Text($0.title).tag($0.name) }
                        }
                        .pickerStyle(.menu).frame(width: 130)
                    }
                }
                group("Startup") {
                    row("Launch at login", "Sits in the menu bar; does nothing until an agent works") {
                        Toggle("", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    }
                }
            }
            .toggleStyle(.switch).labelsHidden()
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10, content: content)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
        }
    }

    private func row<Control: View>(_ title: String, _ detail: String, @ViewBuilder _ control: () -> Control) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            control()
        }
    }
}
