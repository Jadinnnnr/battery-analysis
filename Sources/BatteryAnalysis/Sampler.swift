import Darwin
import Foundation
import IOKit.ps

enum Sampler {
    /// Full executable path for a PID, read in-process (no `ps` launch).
    static func path(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    static func allPIDs() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return pids.prefix(Int(max(got, 0))).filter { $0 > 0 }
    }

    /// Maps an executable path to a user-facing app name, folding helper
    /// processes (e.g. "Chrome Helper") into their parent .app.
    static func appIdentity(_ path: String) -> (name: String, appPath: String?) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            let name = String(parts[i].dropLast(4))
            return (name, "/" + parts[0...i].joined(separator: "/"))
        }
        return (parts.last ?? path, nil)
    }

    /// Rolls per-PID energy impact up into apps, plus each app's bundle path.
    static func identify(_ pidPower: [Int32: Double]) -> (apps: [String: Double], paths: [String: String]) {
        var apps: [String: Double] = [:]
        var paths: [String: String] = [:]
        for (pid, pw) in pidPower {
            guard let p = path(of: pid) else { continue }
            let (name, appPath) = appIdentity(p)
            if name == "top" { continue }   // our own sampler
            apps[name, default: 0] += pw
            if let appPath { paths[name] = appPath }
        }
        return (apps, paths)
    }

    /// One-off sample used at launch so the UI has data before the stream's first interval:
    /// two `top` snapshots 2 s apart (the first has nothing to diff against).
    static func quickSample() -> [Int32: Double] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        p.arguments = ["-l", "2", "-s", "2", "-n", "80", "-o", "power", "-stats", "pid,power"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let lines = out.split(separator: "\n")
        guard let last = lines.lastIndex(where: { $0.hasPrefix("PID") }) else { return [:] }
        var rows: [Int32: Double] = [:]
        for l in lines[(last + 1)...] {
            if let (pid, pw) = TopStream.parseRow(l), pw > 0 { rows[pid] = pw }
        }
        return rows
    }

    static func battery() -> BatteryInfo {
        var info = BatteryInfo()
        let snap = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(snap).takeRetainedValue() as [CFTypeRef]
        guard let ps = list.first,
              let d = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any] else {
            info.hasBattery = false
            return info
        }
        let cur = d[kIOPSCurrentCapacityKey] as? Double ?? (d[kIOPSCurrentCapacityKey] as? Int).map(Double.init) ?? 0
        let max = d[kIOPSMaxCapacityKey] as? Double ?? (d[kIOPSMaxCapacityKey] as? Int).map(Double.init) ?? 100
        info.percent = max > 0 ? cur / max * 100 : cur
        info.charging = d[kIOPSIsChargingKey] as? Bool ?? false
        info.pluggedIn = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        if let m = d[kIOPSTimeToEmptyKey] as? Int, m > 0, !info.pluggedIn { info.minutesRemaining = m }
        return info
    }
}

/// Keeps one `top` running in logging mode. Each sample is an average over the whole interval,
/// and there's no process launch or throwaway first snapshot per tick (~5x less CPU than
/// launching `top -l 2` every time). Thread-safe: all mutable state is confined to `queue`.
final class TopStream: @unchecked Sendable {
    private let interval: Int
    private let rowsPerSample = 80
    private let onSample: ([Int32: Double]) -> Void
    private let queue = DispatchQueue(label: "batteryanalysis.top")

    // Accessed only on `queue`.
    private var process: Process?
    private var buffer = Data()
    private var rows: [Int32: Double] = [:]
    private var rowCount = 0
    private var inTable = false
    private var samplesSeen = 0
    private var stopped = false

    /// `onSample` is called on a background queue.
    init(interval: Int, onSample: @escaping ([Int32: Double]) -> Void) {
        self.interval = interval
        self.onSample = onSample
    }

    func start() { queue.async { self.launch() } }

    func stop() {
        queue.sync {
            stopped = true
            process?.terminate()
        }
    }

    static func parseRow<S: StringProtocol>(_ line: S) -> (Int32, Double)? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        // The x86_64 build of top (Intel Macs, or under Rosetta) marks PIDs with a trailing "*", e.g. "1271*".
        guard f.count >= 2, let pid = Int32(f[0].prefix(while: \.isNumber)), let pw = Double(f[1]) else { return nil }
        return (pid, pw)
    }

    private func launch() {
        guard !stopped else { return }
        buffer = Data(); rows = [:]; rowCount = 0; inTable = false; samplesSeen = 0
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        p.arguments = ["-l", "0", "-s", "\(interval)", "-n", "\(rowsPerSample)", "-o", "power", "-stats", "pid,power"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async { self?.consume(d) }
        }
        // If top ever exits unexpectedly, start a fresh one after a short pause.
        p.terminationHandler = { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 5) { self?.launch() }
        }
        do {
            try p.run()
            process = p
        } catch {
            queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.launch() }
        }
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 10) {
            handle(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("Processes:") { finish(); return }   // header of the next sample
        if line.hasPrefix("PID") { inTable = true; rows = [:]; rowCount = 0; return }
        guard inTable, let (pid, pw) = TopStream.parseRow(line) else { return }
        if pw > 0 { rows[pid] = pw }
        rowCount += 1
        if rowCount >= rowsPerSample { finish() }
    }

    private func finish() {
        guard inTable else { return }
        inTable = false
        samplesSeen += 1
        // top's first sample has nothing to diff against, so its power column isn't meaningful.
        if samplesSeen > 1 { onSample(rows) }
    }
}
