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
        for w in windows {
            (w.contentView as? ScreensaverView)?.stop()
            w.orderOut(nil)
        }
        windows.removeAll()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        NSCursor.unhide()
        previousApp?.activate()
        previousApp = nil
    }
}
