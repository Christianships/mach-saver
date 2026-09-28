import AppKit
import IOKit.pwr_mgt

/// Finds running agent CLIs, and whether any of them is doing work.
///
/// An agent counts as working while it, or anything it started (tools, builds,
/// tests), uses at least `busyShare` of a core, and for `grace` after that so
/// short pauses (waiting on the model) don't count as done. An idle agent
/// sitting at its prompt uses about 1-2%; a working one is well above.
final class AgentMonitor {
    static let busyShare = 0.04
    static let grace: CFTimeInterval = 90

    /// Names of the agents running now, one per process.
    private(set) var running: [String] = []
    private(set) var lastWork = -Double.infinity
    var isWorking: Bool { CACurrentMediaTime() - lastWork < Self.grace }

    // Which pids are agents. Reading a process's arguments is the costly part,
    // so it's done once per process (a pid plus its start time).
    private struct Known { var start: UInt64; var agent: String? }
    private var known: [pid_t: Known] = [:]
    private var knownNames: Set<String> = []
    private var cpu: [pid_t: UInt64] = [:]          // last CPU total (ns) of each agent's process tree
    private var sampledAt = 0.0

    private static let nsPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    func scan(names: Set<String>) {
        if names != knownNames { known = [:]; knownNames = names }
        let now = CACurrentMediaTime()
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))

        var children: [pid_t: [pid_t]] = [:]
        var roots: [(pid: pid_t, name: String)] = []
        var alive = Set<pid_t>()
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            alive.insert(pid)
            children[pid_t(info.pbi_ppid), default: []].append(pid)
            let start = info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
            if known[pid]?.start != start { known[pid] = Known(start: start, agent: Self.agent(pid, names)) }
            if let name = known[pid]?.agent { roots.append((pid, name)) }
        }
        known = known.filter { alive.contains($0.key) }

        // CPU used by each agent and everything under it since the last scan.
        var totals: [pid_t: UInt64] = [:]
        var busy = false
        for root in roots {
            var total: UInt64 = 0, stack = [root.pid], seen = Set<pid_t>()
            while let p = stack.popLast(), seen.insert(p).inserted {
                total &+= Self.cpuTime(p)
                stack += children[p] ?? []
            }
            totals[root.pid] = total
            if let before = cpu[root.pid], sampledAt > 0, total > before, now > sampledAt {
                if Double(total - before) / ((now - sampledAt) * 1e9) >= Self.busyShare { busy = true }
            }
        }
        if busy { lastWork = now }
        cpu = totals
        sampledAt = now
        running = roots.map(\.name)
    }

    private static func cpuTime(_ pid: pid_t) -> UInt64 {
        var t = proc_taskinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &t, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { return 0 }
        return UInt64(Double(t.pti_total_user &+ t.pti_total_system) * nsPerTick)
    }

    /// The agent name this process was started as, if any.
    private static func agent(_ pid: pid_t, _ names: Set<String>) -> String? {
        var name = [CChar](repeating: 0, count: 256)
        var candidates: [String] = []
        if proc_name(pid, &name, UInt32(name.count)) > 0 { candidates.append(String(cString: name)) }
        if let match = candidates.first(where: names.contains) { return match }
        // Claude Code's binary is named after its version (e.g. 2.1.283), so also check
        // argv[0], and argv[1] for agents launched through node/bun/python.
        let args = arguments(pid).prefix(2).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        return args.first(where: names.contains)
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
