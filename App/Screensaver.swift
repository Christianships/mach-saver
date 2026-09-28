import AppKit
import QuartzCore

/// Base class for a screensaver scene. Subclasses override `advance(_:)` to step
/// the animation and `draw(_:)` to render it. The view ticks itself at up to
/// 30fps from the display's own refresh while it's in a window, so it stops
/// drawing on its own when the display sleeps or the window is covered.
class ScreensaverView: NSView {
    private var link: CADisplayLink?
    private var lastTime = CACurrentMediaTime()

    override var isOpaque: Bool { true }

    /// Steps the animation by `dt` seconds. Also called headless by `--snapshot`.
    func advance(_ dt: Double) {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { start() } else { stop() }
    }

    func start() {
        guard link == nil else { return }
        lastTime = CACurrentMediaTime()
        let l = displayLink(target: self, selector: #selector(step(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func step(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        advance(min(0.1, now - lastTime))
        lastTime = now
        needsDisplay = true
    }

    func stop() {
        link?.invalidate()
        link = nil
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
