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
    enum Tab: String, CaseIterable {
        case home = "Home", settings = "Settings"
        var symbol: String {
            switch self { case .home: "house.fill"; case .settings: "gearshape.fill" }
        }
    }
    @Published var tab: Tab = .home

    // From the agent.
    @Published var awake = false
    @Published var heard = false

    // Settings, read and written straight through to the shared defaults.
    @Published var keepAwake = Prefs.keepAwake
    @Published var idleMinutes = Prefs.idleMinutes
    @Published var palette = Afterburner.Settings.palette
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled

    init() {
        Bus.observe(Bus.status) { [weak self] info in
            guard let self else { return }
            awake = info["awake"] as? Bool ?? false
            heard = true
        }
        Bus.post(Bus.request)
    }

    var headline: String {
        guard heard else { return "Connecting to the menu bar…" }
        return awake ? "Keeping your Mac awake" : "Your Mac sleeps as usual"
    }

    // MARK: actions

    func lock() {
        MachSaverPanel.close()
        ScreenLock.lockNow()
    }

    func quit() {
        Bus.post(Bus.command, ["do": "quit"])
        MachSaverPanel.close()
    }

    func setKeepAwake(_ m: KeepAwake) { keepAwake = m; Prefs.keepAwake = m; changed() }
    func setIdle(_ m: Double) { idleMinutes = m; Prefs.idleMinutes = m; changed() }
    func setPalette(_ name: String) { palette = name; Afterburner.Settings.palette = name }

    func setLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSSound.beep() }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Tells the agent to re-read settings now rather than on its next tick.
    private func changed() { Bus.post(Bus.command, ["do": "refresh"]) }
}

// MARK: panel window

/// A floating dark HUD. Esc or clicking elsewhere dismisses it.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func resignKey() {
        super.resignKey()
        if NSApp.modalWindow == nil { close() }
    }
}

/// Like MouseSkins, the panel runs in its own short-lived process
/// (`MachSaver --panel`, started by the menu bar agent) and quits when it
/// closes, so the agent that sits in the menu bar all day never loads
/// SwiftUI. It opens in the middle of the screen with the pointer.
enum MachSaverPanel {
    static let size = NSSize(width: 440, height: 640)
    private static var panel: FloatingPanel?

    static func show() {
        let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.appearance = NSAppearance(named: .darkAqua)
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
        let f = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2,
                          width: size.width, height: size.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    static func close() { panel?.close() }
}

/// Starts and stops the panel process from the menu bar agent.
enum PanelProcess {
    private static var process: Process?

    static var isOpen: Bool { process?.isRunning == true }

    /// Clicking the menu bar icon again closes it.
    static func toggle() {
        if isOpen { process?.terminate(); process = nil } else { open() }
    }

    static func open() {
        guard !isOpen else { return }
        let p = Process()
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["--panel"]
        do { try p.run(); process = p } catch { NSSound.beep() }
    }
}

enum Accent {
    static let color = Color(red: 0.66, green: 0.33, blue: 0.97)     // #A855F7, MACH's violet
    static let deep = Color(red: 0.42, green: 0.13, blue: 0.66)      // #6B21A8
}

extension RGB {
    var color: Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
}

// MARK: shell

struct PanelView: View {
    @EnvironmentObject var model: PanelModel

    var body: some View {
        VStack(spacing: 14) {
            header
            tabs
            Group {
                switch model.tab {
                case .home: HomeView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .background(Color.black.opacity(0.45))      // darker than the stock HUD material
        .background(alignment: .top) {
            // A faint violet glow behind the header.
            RadialGradient(colors: [Accent.color.opacity(0.22), .clear], center: .top, startRadius: 0, endRadius: 260)
                .frame(height: 220).allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mach Saver").font(.system(size: 15, weight: .bold))
                HStack(spacing: 5) {
                    Circle().fill(model.awake ? Color.green : Color.secondary.opacity(0.6)).frame(width: 6, height: 6)
                    Text(model.headline).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            IconButton("lock.fill", "Lock screen") { model.lock() }
        }
        .padding(.top, 4)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(PanelModel.Tab.allCases, id: \.self) { tab in
                let on = model.tab == tab
                Button { withAnimation(.easeOut(duration: 0.15)) { model.tab = tab } } label: {
                    Label(tab.rawValue, systemImage: tab.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Accent.color.opacity(0.85) : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.07)))
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(filled ? Color.white : tint ?? Color.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(filled ? AnyShapeStyle(tint ?? .accentColor) : AnyShapeStyle(Color.primary.opacity(0.08))))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A titled group of controls on a rounded card.
private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).kerning(0.6)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
    }
}

/// The screensaver itself, running live in the panel.
struct LivePreview: NSViewRepresentable {
    let palette: String

    final class Holder { var palette = "" }
    func makeCoordinator() -> Holder { Holder() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard context.coordinator.palette != palette else { return }
        context.coordinator.palette = palette
        v.subviews.forEach { $0.removeFromSuperview() }
        let scene = Afterburner(frame: v.bounds, palette: Palette.named(palette), logo: Afterburner.Settings.loadLogo())
        scene.autoresizingMask = [.width, .height]
        v.addSubview(scene)
    }
}

// MARK: home

struct HomeView: View {
    @EnvironmentObject var model: PanelModel

    var body: some View {
        VStack(spacing: 12) {
            hero
            PanelSection(title: "Colour") {
                HStack(spacing: 8) {
                    ForEach(Palette.all, id: \.name) { swatch($0) }
                }
            }
            PanelSection(title: "Keep awake") {
                Picker("", selection: Binding(get: { model.keepAwake }, set: { model.setKeepAwake($0) })) {
                    ForEach(KeepAwake.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            PanelSection(title: "Screensaver when you're away for") {
                Picker("", selection: Binding(get: { model.idleMinutes }, set: { model.setIdle($0) })) {
                    ForEach([1.0, 2, 5, 10, 15, 0], id: \.self) { m in Text(m == 0 ? "Never" : "\(Int(m)) min").tag(m) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
    }

    private var hero: some View {
        LivePreview(palette: model.palette)
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08)))
    }

    private func swatch(_ p: Palette) -> some View {
        let on = model.palette == p.name
        let stops = (p.text ?? p.accent).map(\.color)
        return Button { model.setPalette(p.name) } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(p.background.color)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .padding(7)
                }
                .frame(height: 34)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Accent.color : Color.white.opacity(0.1), lineWidth: on ? 2 : 1))
                Text(p.title).font(.system(size: 10, weight: on ? .bold : .medium))
                    .foregroundStyle(on ? Color.primary : Color.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: settings

struct SettingsView: View {
    @EnvironmentObject var model: PanelModel

    var body: some View {
        VStack(spacing: 12) {
            PanelSection(title: "Startup") {
                row("Launch at login", "Waits in the menu bar until you need it") {
                    Toggle("", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            PanelSection(title: "Screensaver") {
                row("Show it yourself", "Your AeroSpace binding runs `open -g mach-saver://show`") {
                    Text("Super + |").font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.1)))
                }
                Divider().opacity(0.4)
                row("Any key or mouse move", "Dismisses it and lets your Mac sleep as usual again") { EmptyView() }
            }
            PanelSection(title: "Mach Saver") {
                HStack(spacing: 8) {
                    wide("Lock Screen", "lock.fill") { model.lock() }
                    wide("Quit", "power", tint: .red) { model.quit() }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func row<Control: View>(_ title: String, _ detail: String, @ViewBuilder _ control: () -> Control) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            control()
        }
    }

    private func wide(_ title: String, _ symbol: String, tint: Color = .primary, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}
