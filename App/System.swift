import AppKit
import IOKit.pwr_mgt

/// Finds running agent CLIs by the name they were started as.
enum Agents {
    static func running(named names: Set<String>) -> [String] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var name = [CChar](repeating: 0, count: 256)
        var found: [String] = []
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var candidates: [String] = []
            if proc_name(pid, &name, UInt32(name.count)) > 0 { candidates.append(String(cString: name)) }
            // Claude Code's binary is named after its version (e.g. 2.1.283), so also check
            // argv[0], and argv[1] for agents launched through node/bun/python.
            let args = arguments(pid).prefix(2).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            candidates += args
            if let match = candidates.first(where: names.contains) { found.append(match) }
        }
        return found
    }

    private static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        // Layout: argc, exec path, NUL padding, then argv strings.
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < min(argc, 2) && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            out.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }
}

/// Holds the "don't sleep" power assertion, like Amphetamine or `caffeinate -d`.
final class Awake {
    private var assertion: IOPMAssertionID = 0
    private var activity: IOPMAssertionID = 0

    var isHeld: Bool { assertion != 0 }

    func hold(_ on: Bool) {
        if on, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Mach: agent session running" as CFString, &assertion)
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    /// Resets macOS's idle timer so its own screen saver and lock don't start on top of ours.
    func nudge() {
        IOPMAssertionDeclareUserActivity("Mach screensaver" as CFString, kIOPMUserActiveLocal, &activity)
    }
}

enum Idle {
    /// Seconds since the last real keyboard/mouse/trackpad input. Uses the hardware
    /// counter because `Awake.nudge()` resets the session one.
    static var seconds: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }
}

enum ScreenLock {
    /// Locks immediately, same as Ctrl-Cmd-Q.
    static func lockNow() {
        typealias Fn = @convention(c) () -> Void
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            unsafeBitCast(sym, to: Fn.self)()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }
}
