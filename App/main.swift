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
        // Clicking the icon shows the quick menu; Settings… in it opens the panel.
        statusItem.menu = menu
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
            PanelProcess.open()
        }
    }

    /// Opening the app again while it's running (Spotlight, Finder, Dock) opens the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        PanelProcess.open()
        return false
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
            statusItem.button?.image = awake.isHeld ? MenuIcon.awake : MenuIcon.resting
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
            // A saved screensaver, by name (any case) or id.
            let want = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            var lib = Library.load()
            if let s = lib.savers.first(where: { $0.name.lowercased() == want.lowercased() || $0.id == want }) {
                lib.active = s.id
                lib.save()
            }
        default: break
        }
    }

    // MARK: - Menu

    /// The quick menu: switch screensaver or colour in one click; everything
    /// else is in the panel (Settings…).
    func menuNeedsUpdate(_ menu: NSMenu) {
        update(scan: true)
        menu.removeAllItems()
        menu.addItem(Menus.disabled(awake.isHeld ? "Keeping your Mac awake" : "Your Mac sleeps as usual"))

        let lib = Library.load()
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Screensavers"))
        for s in lib.savers {
            let item = Menus.item(s.name, checked: s.id == lib.active) {
                var l = Library.load(); l.active = s.id; l.save()
            }
            item.image = Menus.swatch(Palette.named(s.palette))
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Colors"))
        let current = lib.activeSaver.palette
        for p in Palette.builtIn + lib.colorways.map(\.palette) {
            let item = Menus.item(p.title, checked: p.name == current) {
                var l = Library.load()
                if let i = l.savers.firstIndex(where: { $0.id == l.active }) { l.savers[i].palette = p.name; l.save() }
            }
            item.image = Menus.swatch(p)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let settings = Menus.item("Settings…") { PanelProcess.open() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(Menus.item("Quit Mach Saver") { NSApp.terminate(nil) })
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
    let lib = Library.load()
    for s in lib.savers { print("\(s.id == lib.active ? "*" : " ") \(s.name)  (\(s.text), \(Palette.named(s.palette).title))") }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
