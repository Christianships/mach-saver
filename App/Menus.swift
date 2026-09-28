import AppKit

/// Small helpers for building the menu bar menu out of closures.
enum Menus {
    static func item(_ title: String, checked: Bool = false, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title: title, action: action)
        i.state = checked ? .on : .off
        return i
    }

    static func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    /// A small rounded swatch of a palette: its background with the text colours across it.
    static func swatch(_ p: Palette) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSColor(cgColor: p.background.cg())?.setFill()
            box.fill()
            let colors = (p.text ?? p.accent).compactMap { NSColor(cgColor: $0.cg()) }
            NSGradient(colors: colors)?.draw(in: NSBezierPath(roundedRect: r.insetBy(dx: 3.5, dy: 5), xRadius: 2, yRadius: 2), angle: 0)
            NSColor.white.withAlphaComponent(0.25).setStroke()
            box.lineWidth = 0.5
            box.stroke()
            return true
        }
    }

    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu()
        items.forEach(m.addItem)
        i.submenu = m
        return i
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}
