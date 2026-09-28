import AppKit
import QuartzCore

/// Base class for a screensaver scene. Subclasses override `advance(_:)` to step
/// the animation and `draw(_:)` to render it; the view ticks itself at 30fps
/// while it's in a window.
class ScreensaverView: NSView {
    private var timer: Timer?
    private var lastTime = CACurrentMediaTime()

    override var isOpaque: Bool { true }

    /// Steps the animation by `dt` seconds. Also called headless by `--snapshot`.
    func advance(_ dt: Double) {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { start() } else { stop() }
    }

    func start() {
        guard timer == nil else { return }
        lastTime = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.advance(min(0.1, now - self.lastTime))
            self.lastTime = now
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

struct Screensaver {
    let id: String
    let title: String
    let make: (NSRect) -> ScreensaverView
    /// Settings shown under this screensaver in the menu bar.
    var options: () -> [NSMenuItem] = { [] }
}

/// Every screensaver the app knows about. Add new ones here.
enum Screensavers {
    static let all: [Screensaver] = [Afterburner.screensaver]

    static var active: Screensaver { all.first { $0.id == Prefs.screensaver } ?? all[0] }
}
