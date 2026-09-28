import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let awake = Awake()
    private let saver = SaverController()
    private let monitor = AgentMonitor()
    private var lastScan: CFTimeInterval = 0
    private var tick: Timer?
    private var shownIcon: Bool?
    private var sentStatus: [String: AnyHashable] = [:]
    /// A manual session (opening the app): stay awake with the screensaver up,
    /// agents or not, until you come back and dismiss it.
    private var sessionActive = false

    /// How often to check on things: every second while the screensaver is up
    /// (to notice input), otherwise every 5s. Agents are scanned every 10s.
    private static let busyTick = 1.0, idleTick = 5.0, scanEvery = 10.0

    func applicationWillFinishLaunching(_ note: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        Prefs.registerDefaults()
        menu.delegate = self
        // Left click opens the panel under the icon; right click shows the menu.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // The panel (its own process) asks for status when it opens and sends commands.
        Bus.observe(Bus.request) { [weak self] _ in self?.sentStatus = [:]; self?.update() }
        Bus.observe(Bus.command) { [weak self] info in
            switch info["do"] as? String {
            case "refresh": self?.update(scan: true)
            case "quit": NSApp.terminate(nil)
            default: break
            }
        }
        saver.onUserDismiss = { [weak self] in
            self?.sessionActive = false
            self?.update()
        }
        update(scan: true)

        // Opening the app yourself opens the panel. Launching at login, from a
        // mach-saver:// link, or with --background just puts it in the menu bar.
        // The screensaver itself only comes up from mach-saver://show (the
        // AeroSpace binding) or when an agent is working and you're away.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let openedByUser = (note.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) ?? false
        if CommandLine.arguments.contains("--preview") {
            saver.show(preview: true)
        } else if openedByUser && !atLogin && !CommandLine.arguments.contains("--background") {
            PanelProcess.open(anchor: panelAnchor)
        }
    }

    /// Opening the app again while it's running (Spotlight, Finder, Dock) opens the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        PanelProcess.open(anchor: panelAnchor)
        return false
    }

    /// Top centre just under the menu bar icon, in screen points.
    private var panelAnchor: NSPoint? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let r = window.convertToScreen(button.convert(button.bounds, to: nil))
        return NSPoint(x: r.midX, y: r.minY)
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil       // detach so the next click comes back here
            return
        }
        PanelProcess.toggle(anchor: panelAnchor)
    }

    func applicationWillTerminate(_ note: Notification) {
        saver.dismiss()
        awake.hold(false)
    }

    private var shouldStayAwake: Bool {
        if sessionActive { return true }
        return switch Prefs.keepAwake {
        case .automatic: monitor.isWorking
        case .always: true
        case .off: false
        }
    }

    private func update(scan: Bool = false) {
        let now = CACurrentMediaTime()
        if scan || now - lastScan >= Self.scanEvery - 0.5 {
            monitor.scan(names: Set(Prefs.agentNames))
            lastScan = now
        }
        let stayAwake = shouldStayAwake
        // Anything on screen keeps the display on, even a one-off `show`.
        awake.hold(stayAwake || saver.isShowing)
        if shownIcon != awake.isHeld {
            shownIcon = awake.isHeld
            statusItem.button?.image = NSImage(systemSymbolName: awake.isHeld ? "flame.fill" : "flame",
                                               accessibilityDescription: "Mach Saver")
        }
        defer { schedule(); broadcast() }

        if saver.isShowing {
            if !stayAwake && !saver.isPreview {
                // Agents finished: step aside so macOS can sleep and lock as normal.
                saver.dismiss()
            } else if saver.shownFor > 1.5 && Idle.seconds < 1.5 {
                // Input the event monitors can't see (e.g. keys while another app has focus).
                saver.dismiss()
                sessionActive = false
            } else {
                awake.nudge()
            }
        } else if stayAwake, Prefs.idleMinutes > 0, Idle.seconds >= Prefs.idleMinutes * 60 {
            saver.show()
        }
        if !saver.isShowing { awake.endNudges() }
    }

    /// Tells an open panel what's going on, when it changes.
    private func broadcast() {
        let status: [String: AnyHashable] = ["agents": monitor.running, "working": monitor.isWorking,
                                             "awake": awake.isHeld, "session": sessionActive]
        guard status != sentStatus else { return }
        sentStatus = status
        Bus.post(Bus.status, status)
    }

    /// Re-arms the timer when the pace should change. The tolerance lets macOS
    /// batch our wake-ups with others.
    private func schedule() {
        let interval = saver.isShowing ? Self.busyTick : Self.idleTick
        guard tick?.timeInterval != interval else { return }
        tick?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.update() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    // MARK: - Sessions

    func startSession() {
        sessionActive = true
        saver.show()
        update()
    }

    func endSession() {
        sessionActive = false
        saver.dismiss()
        update()
    }

    func show() {
        saver.show(preview: true)
        update()
    }

    /// mach-saver://show|start|stop|toggle and mach-saver://use/<screensaver>.
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s), let host = url.host else { return }
        switch host {
        case "show": show()
        case "start": startSession()
        case "stop": endSession()
        case "toggle": sessionActive ? endSession() : startSession()
        case "use":
            let id = url.lastPathComponent
            if Screensavers.all.contains(where: { $0.id == id }) { Prefs.screensaver = id }
        default: break
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        update(scan: true)
        menu.removeAllItems()

        let counts = Dictionary(monitor.running.map { ($0, 1) }, uniquingKeysWith: +)
        let summary = counts.isEmpty ? "No agent sessions"
            : counts.sorted { $0.key < $1.key }.map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }.joined(separator: ", ")
            + (monitor.isWorking ? " (working)" : " (idle)")
        menu.addItem(Menus.disabled("Mach Saver — \(summary)"))
        menu.addItem(Menus.disabled(awake.isHeld ? "Keeping your Mac awake" : "Not keeping your Mac awake"))
        menu.addItem(.separator())
        menu.addItem(Menus.item("Open Mach Saver…") { PanelProcess.open(anchor: self.panelAnchor) })
        menu.addItem(.separator())

        let active = Screensavers.active
        menu.addItem(Menus.submenu("Screensaver: \(active.title)",
            Screensavers.all.map { s in Menus.item(s.title, checked: s.id == active.id) { Prefs.screensaver = s.id } }
            + [.separator()] + active.options()))
        menu.addItem(Menus.submenu("Keep Awake", KeepAwake.allCases.map { mode in
            Menus.item(mode.title, checked: Prefs.keepAwake == mode) { Prefs.keepAwake = mode; self.update() }
        }))
        menu.addItem(Menus.submenu("Screensaver After", [1.0, 2, 5, 10, 15, 0].map { m in
            Menus.item(m == 0 ? "Never" : "\(Int(m)) min", checked: Prefs.idleMinutes == m) { Prefs.idleMinutes = m }
        }))
        menu.addItem(.separator())

        menu.addItem(Menus.item("Lock Screen") { ScreenLock.lockNow() })
        menu.addItem(Menus.item("Launch at Login", checked: SMAppService.mainApp.status == .enabled) { self.toggleLoginItem() })
        menu.addItem(Menus.item("Quit Mach Saver") { NSApp.terminate(nil) })
    }

    private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// `MachSaver --snapshot out.png [seconds] [screensaver]` renders one frame without showing anything.
func snapshot(_ args: [String]) {
    let seconds = args.count > 1 ? Double(args[1]) ?? 4 : 4
    let saver = args.count > 2 ? Screensavers.all.first { $0.id == args[2] } ?? Screensavers.active : Screensavers.active
    let size = NSScreen.main?.frame.size ?? NSSize(width: 1512, height: 982)
    let view = saver.make(NSRect(origin: .zero, size: size))
    for _ in 0..<Int(seconds * 30) { view.advance(1.0 / 30) }
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[0]))
}

Prefs.registerDefaults()
// `--panel` is the settings panel, its own short-lived process (see MachSaverPanel).
if CommandLine.arguments.contains("--panel") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async { MachSaverPanel.show() }
    app.run()
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
    snapshot(Array(CommandLine.arguments[(i + 1)...]))
    exit(0)
}
if CommandLine.arguments.contains("--list") {
    for s in Screensavers.all { print("\(s.id == Screensavers.active.id ? "*" : " ") \(s.id)") }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
