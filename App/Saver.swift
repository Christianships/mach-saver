import AppKit

private final class SaverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Full-screen scene on every display, dismissed by any real input.
final class SaverController {
    private var windows: [NSWindow] = []
    private var monitors: [Any] = []
    private var shownAt: CFTimeInterval = 0
    private var mouseStart = NSPoint.zero
    private var previousApp: NSRunningApplication?

    private(set) var isPreview = false
    /// Called when real input dismisses the screensaver (not when the app hides it).
    var onUserDismiss: (() -> Void)?
    var isShowing: Bool { !windows.isEmpty }
    var shownFor: CFTimeInterval { CACurrentMediaTime() - shownAt }

    func show(preview: Bool = false) {
        guard !isShowing else { return }
        isPreview = preview
        previousApp = NSWorkspace.shared.frontmostApplication
        let screensaver = Screensavers.active

        for screen in NSScreen.screens {
            let w = SaverWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.backgroundColor = .black
            w.isOpaque = true
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.contentView = screensaver.make(NSRect(origin: .zero, size: screen.frame.size))
            w.orderFrontRegardless()
            windows.append(w)
        }
        windows.first?.makeKey()
        // Take focus so typing dismisses the screensaver instead of landing in the app behind it.
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.hide()
        shownAt = CACurrentMediaTime()
        mouseStart = NSEvent.mouseLocation

        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                           .mouseMoved, .leftMouseDragged, .scrollWheel]
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            self?.handle(e)
            return nil
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(m)
        }
    }

    private func handle(_ e: NSEvent) {
        // Ignore the tail of whatever opened a preview.
        guard shownFor > 0.8 else { return }
        if e.type == .mouseMoved || e.type == .leftMouseDragged {
            let p = NSEvent.mouseLocation
            guard hypot(p.x - mouseStart.x, p.y - mouseStart.y) > 12 else { return }
        }
        dismiss()
        onUserDismiss?()
    }

    func dismiss() {
        guard isShowing else { return }
        // Close, don't just hide: a hidden window keeps its full-screen
        // backing buffers (tens of MB per display) until the app quits.
        for w in windows {
            (w.contentView as? ScreensaverView)?.stop()
            w.contentView = nil
            w.orderOut(nil)
            w.close()
        }
        windows.removeAll()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        NSCursor.unhide()
        previousApp?.activate()
        previousApp = nil
    }
}

/// Runs the screensaver as its own `--saver` process, so the menu bar agent
/// never draws full screen. Core Animation keeps a full-screen frame cached
/// (40+ MB) for the life of whichever process drew it; this way it goes away
/// with the screensaver instead of staying in the agent.
final class SaverProcess {
    private var process: Process?
    private var shownAt: CFTimeInterval = 0

    private(set) var isPreview = false
    /// Called when real input dismisses the screensaver (not when the app hides it).
    var onUserDismiss: (() -> Void)?
    var isShowing: Bool { process != nil }
    var shownFor: CFTimeInterval { CACurrentMediaTime() - shownAt }

    func show(preview: Bool = false) {
        guard !isShowing else { return }
        let p = Process()
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["--saver"] + (preview ? ["--preview"] : [])
        // The child exits by itself only when you dismiss it; our own dismiss() forgets it first.
        p.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                self.process = nil
                self.onUserDismiss?()
            }
        }
        do { try p.run() } catch { NSSound.beep(); return }
        process = p
        isPreview = preview
        shownAt = CACurrentMediaTime()
    }

    func dismiss() {
        guard let p = process else { return }
        process = nil
        p.terminate()
    }
}

/// `MachSaver --saver [--preview]`: shows the screensaver and exits when it's
/// dismissed, by input or by SIGTERM from the agent.
func runSaverProcess(preview: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let saver = SaverController()
    saver.onUserDismiss = { exit(0) }
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler { saver.dismiss(); exit(0) }
    term.resume()
    // Never outlive the agent, or the screen would stay covered.
    let parent = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
    parent.setEventHandler { saver.dismiss(); exit(0) }
    parent.resume()
    DispatchQueue.main.async { saver.show(preview: preview) }
    app.run()
    exit(0)
}
