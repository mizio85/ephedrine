//
//  AgentDetector.swift
//  Ephedrine
//
//  Process discovery and CPU accounting.
//
//  Detection strategy (two phases, both case-insensitive):
//
//    Phase 1 — process name + executable path
//      `proc_name()` gives the (truncated to 15 chars) process name; `proc_pidpath()` gives the
//      real executable path. Long patterns are matched as substrings of any path component or of
//      the process name; short patterns (≤ 4 chars, e.g. "amp") must match a whole token to avoid
//      false positives.
//
//    Phase 2 — command line (only for known wrapper interpreters)
//      Most agents ship as Node/Bun/Python programs, so the real agent name lives in the command
//      line of `node`, `bun`, `python3`, … rather than in the process name. For these wrappers we
//      read the full argv via `KERN_PROCARGS2` and match against every argument's basename.
//
//  Everything is read-only sysctl/proc APIs: no subprocesses, no special privileges, and the
//  whole scan of a typical macOS process table (~500–800 processes) takes a few milliseconds.
//
//  CPU accounting uses `proc_pid_rusage()` deltas: see `CPUSampler`. Note that the rusage
//  counters are expressed in mach timebase units (NOT nanoseconds) on Apple Silicon, so they must
//  be converted with `mach_timebase_info` — a classic bug that under-reports CPU by ~42×.
//

import Darwin
import Foundation

/// Whether a detected agent is currently doing work or waiting for input.
enum AgentActivity {
    case working
    case waiting
}

/// One monitored process matching one of the configured patterns.
struct DetectedAgent: Identifiable {
    let pid: pid_t
    /// The pattern that matched this process (used as the display name / grouping key).
    let pattern: String
    /// Process name from `proc_name()` (short, may be truncated).
    let name: String
    /// Executable path (or command line when the path is unavailable).
    let path: String
    /// CPU usage fraction since the previous sample (0…1 per core); `nil` on the first sample.
    var cpuPercent: Double?
    /// Filled in by `AppDelegate` after consulting session state / CPU heuristics.
    var activity: AgentActivity = .working

    var id: pid_t { pid }
}

/// Read-only process table scanner plus the matching rules.
enum ProcessScanner {

    /// Utility processes whose command lines frequently contain pattern strings but which are not
    /// agents (e.g. `grep codex` or `vim opencode.log`). Ignored entirely.
    private static let ignoredNames: Set<String> = [
        "grep", "egrep", "fgrep", "rg", "ag", "ack", "pgrep", "pkill", "ps",
        "xargs", "fzf", "fd", "find", "mdfind", "awk", "sed", "vim", "nvim",
        "less", "more", "tail", "head", "cat", "bat", "watch", "man"
    ]

    /// Interpreters that host agents: for these we also inspect the command line.
    /// Shells (`sh`, `bash`, `zsh`, …) are intentionally absent: matching shell command lines
    /// produces false positives (e.g. any script that merely mentions "codex").
    private static let wrapperNames: Set<String> = [
        "node", "bun", "deno", "python", "python3", "npm", "npx", "pnpm",
        "yarn", "uv", "uvx", "ruby", "perl", "java", "dotnet", "cargo", "go"
    ]

    // MARK: - Public API

    /// Returns every process matching at least one pattern, sorted by pid.
    static func scan(patterns: [String]) -> [DetectedAgent] {
        guard !patterns.isEmpty else { return [] }
        let lowered = patterns.map { $0.lowercased() }
        let ownPID = getpid()
        var agents: [DetectedAgent] = []

        for process in processList() {
            let pid = process.pid
            // Skip kernel/launchd and ourselves (our own path contains "Ephedrine" anyway).
            if pid <= 1 || pid == ownPID { continue }
            let name = process.name
            if name.isEmpty || ignoredNames.contains(name) { continue }

            let path = executablePath(pid: pid) ?? ""
            if path.contains("Ephedrine") { continue }

            // Phase 1: cheap name/path match.
            var match = matches(lowered: lowered, processName: name, path: path, args: "")
            var args = ""

            // Phase 2: wrappers only — inspect the real command line. `p_comm` is truncated to
            // 15 chars and can even hold a path fragment, so check the executable basename too.
            if match == nil, isWrapper(name) || isWrapper(executableBaseName(path)), let commandLine = commandLine(pid: pid) {
                args = commandLine
                match = matches(lowered: lowered, processName: name, path: path, args: commandLine)
            }

            if let pattern = match {
                agents.append(DetectedAgent(
                    pid: pid,
                    pattern: pattern,
                    name: name,
                    path: path.isEmpty ? args : path
                ))
            }
        }

        return agents.sorted { $0.pid < $1.pid }
    }

    /// True when the process is a known interpreter that may host an agent.
    ///
    /// Versioned interpreters (`python3.14`, `node20`, `go1.22`) are recognised by their numeric
    /// suffix, while unrelated names sharing a prefix (`goland`, `node_exporter`) are rejected.
    private static func isWrapper(_ name: String) -> Bool {
        let base = (name as NSString).lastPathComponent.lowercased()
        guard !base.isEmpty else { return false }
        for wrapper in wrapperNames {
            if base == wrapper { return true }
            if base.hasPrefix(wrapper) {
                let suffix = base.dropFirst(wrapper.count)
                if !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) {
                    return true
                }
            }
        }
        return false
    }

    private static func executableBaseName(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return (path as NSString).lastPathComponent
    }

    /// mach timebase, read once: `numer/denom` converts timebase ticks to nanoseconds.
    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Total CPU time (user + system) consumed by `pid`, in seconds, or `nil` if not readable.
    static func cpuTime(pid: pid_t) -> Double? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
            }
        }
        guard result == 0 else { return nil }
        let ticks = Double(info.ri_user_time) + Double(info.ri_system_time)
        // rusage values use mach timebase units; convert to nanoseconds via the timebase.
        let nanoseconds = ticks * Double(machTimebase.numer) / Double(machTimebase.denom)
        return nanoseconds / 1_000_000_000.0
    }

    /// Process name (short) for an arbitrary pid.
    static func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Parent pid for an arbitrary pid, or `nil` if it cannot be read.
    static func parentPID(pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    /// Walks the parent chain looking for a process whose name contains `pattern`.
    ///
    /// Used by the reporter CLI: when an agent invokes `Ephedrine --report …` without an
    /// explicit `--pid`, the agent is (transitively) the parent of the reporter process. This is
    /// how, for example, a Codex `notify` invocation is attributed to the right Codex process.
    static func ancestorPID(matching pattern: String) -> pid_t? {
        let wanted = pattern.lowercased()
        guard wanted.count >= 3, wanted != "unknown" else { return nil }
        var pid = getppid()
        for _ in 0..<16 { // bounded walk: never loop forever on a corrupted table
            if pid <= 1 { return nil }
            if let name = processName(pid: pid), name.lowercased().contains(wanted) {
                return pid
            }
            guard let parent = parentPID(pid: pid) else { return nil }
            pid = parent
        }
        return nil
    }

    // MARK: - Process table

    private struct RawProcess {
        let pid: pid_t
        let name: String
    }

    /// Full process list via `KERN_PROC_ALL`.
    private static func processList() -> [RawProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        // Allocate a little extra: the table can grow between the two sysctl calls.
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = buffer.count * stride
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [] }

        let count = min(size / stride, buffer.count)
        var result: [RawProcess] = []
        result.reserveCapacity(count)
        for process in buffer.prefix(count) {
            let pid = process.kp_proc.p_pid
            if pid <= 0 { continue }
            // `p_comm` is a fixed 16-byte C string; read it as such.
            let name = withUnsafeBytes(of: process.kp_proc.p_comm) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            result.append(RawProcess(pid: pid, name: name))
        }
        return result
    }

    /// Executable path for a pid (`proc_pidpath`), or `nil` if not permitted/readable.
    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Full command line for a pid via `KERN_PROCARGS2`.
    ///
    /// Layout of the returned buffer: `argc` (Int32), the executable path, then `argc`
    /// NUL-terminated arguments. The returned string is the arguments joined by spaces.
    private static func commandLine(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var offset = MemoryLayout<Int32>.size

        // Skip the executable path and the padding NULs that follow it.
        while offset < size, buffer[offset] != 0 { offset += 1 }
        while offset < size, buffer[offset] == 0 { offset += 1 }

        var arguments: [String] = []
        var index = 0
        while index < argc, offset < size {
            let start = offset
            while offset < size, buffer[offset] != 0 { offset += 1 }
            if offset > start, let argument = String(bytes: buffer[start..<offset], encoding: .utf8) {
                arguments.append(argument)
            }
            offset += 1
            index += 1
        }
        return arguments.isEmpty ? nil : arguments.joined(separator: " ")
    }

    // MARK: - Matching rules

    /// Returns the first pattern matching the process, or `nil`.
    private static func matches(lowered patterns: [String], processName: String, path: String, args: String) -> String? {
        let tokens = tokenSet(processName: processName.lowercased(), path: path.lowercased(), args: args)
        for pattern in patterns where !pattern.isEmpty {
            if pattern.count <= 4 {
                // Short patterns must match a whole token ("amp" ≠ "example").
                if tokens.contains(pattern) { return pattern }
            } else if tokens.contains(where: { $0.contains(pattern) }) {
                return pattern
            }
        }
        return nil
    }

    /// Set of matchable tokens: process name, every path component and every argument basename.
    private static func tokenSet(processName: String, path: String, args: String) -> Set<String> {
        var tokens: Set<String> = [processName]
        for component in path.split(separator: "/") {
            tokens.insert(String(component))
        }
        for argument in args.split(separator: " ") {
            tokens.insert((String(argument) as NSString).lastPathComponent.lowercased())
        }
        return tokens
    }
}

/// Caches the previous CPU sample per pid and computes usage fractions between ticks.
final class AgentDetector {

    private let sampler = CPUSampler()

    /// Scans the process table and enriches results with CPU usage since the previous call.
    func detect(patterns: [String]) -> [DetectedAgent] {
        var agents = ProcessScanner.scan(patterns: patterns)
        let fractions = sampler.sample(pids: agents.map(\.pid))
        for index in agents.indices {
            agents[index].cpuPercent = fractions[agents[index].pid]
        }
        return agents
    }
}

/// Computes per-pid CPU fractions between two consecutive samples.
private final class CPUSampler {
    private var previous: [pid_t: (cpu: Double, at: TimeInterval)] = [:]

    /// Returns `pid → fraction of one core` for pids that had a previous sample.
    /// A missing entry means "unknown yet" (first sample after the process appeared).
    func sample(pids: [pid_t]) -> [pid_t: Double] {
        let now = Date().timeIntervalSinceReferenceDate
        var current: [pid_t: (cpu: Double, at: TimeInterval)] = [:]
        var fractions: [pid_t: Double] = [:]

        for pid in pids {
            guard let cpu = ProcessScanner.cpuTime(pid: pid) else { continue }
            current[pid] = (cpu, now)
            if let last = previous[pid] {
                let elapsed = now - last.at
                let delta = cpu - last.cpu
                // Ignore sub-tick intervals and counter resets (pid reuse).
                if elapsed > 0.2, delta >= 0 {
                    fractions[pid] = delta / elapsed
                }
            }
        }

        // Keep only live pids so the dictionary cannot grow forever.
        previous = current
        return fractions
    }
}
