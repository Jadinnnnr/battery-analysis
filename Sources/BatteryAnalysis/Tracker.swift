import AppKit
import Foundation
import SwiftUI

/// The few values the menu bar icon needs. Published separately so a new sample doesn't
/// rebuild the whole app; the icon only redraws when one of these actually changes.
@MainActor
final class MenuBarStatus: ObservableObject {
    static let shared = MenuBarStatus()
    @Published var suggesting = false
    @Published var fallbackWatts: Double?   // battery telemetry, used when the fast sensor isn't available
}

@MainActor
final class Tracker: ObservableObject {
    static let shared = Tracker()
    @Published var samples: [Sample] = [] { didSet { version &+= 1 } }
    @Published var battery = Sampler.battery()
    @Published var appPaths: [String: String] = [:] { didSet { version &+= 1 } }
    @Published var health: BatteryHealth? = HealthReader.read()
    @Published var lowPower = LowPower.isEnabled()

    /// Bumped whenever samples or app paths change; cached analyses are reused until it moves,
    /// so re-renders (typing in search, toggling tabs) don't rescan up to 30 days of history.
    private var version = 0
    private var cache: [String: CacheEntry] = [:]
    private var cacheVersion = -1
    private struct CacheEntry {
        let version: Int
        let at: Double
        let maxAge: Double
        let value: Any
    }

    nonisolated static let interval = 30
    private let keep: Double = 30 * 86400
    private let dir: URL
    private var file: URL { dir.appendingPathComponent("samples.jsonl") }
    private var pathsFile: URL { dir.appendingPathComponent("paths.json") }
    /// All disk writes go through one serial queue, so appends and rewrites never interleave.
    private let io = DispatchQueue(label: "batteryanalysis.io", qos: .utility)
    private var stream: TopStream?

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BatteryAnalysis")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: pathsFile),
           let p = try? JSONDecoder().decode([String: String].self, from: d) { appPaths = p }
        loadHistory()

        // One quick sample so the UI has data right away; the stream's first real sample lands after one interval.
        Task {
            let rows = await Task.detached(priority: .utility) { Sampler.quickSample() }.value
            record(rows)
        }
        let s = TopStream(interval: Tracker.interval) { [weak self] rows in
            Task { @MainActor in self?.record(rows) }
        }
        s.start()
        stream = s

        // Battery telemetry (the menu bar wattage) changes about once a minute; checking every 10 s
        // shows a new reading within seconds of it landing. Cheap IOKit reads, no `top`.
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPower() }
        }
        t.tolerance = 2   // let macOS coalesce the wakeup with others
        RunLoop.main.add(t, forMode: .common)

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak s] _ in
            s?.stop()
        }
        // Low Power Mode changes are pushed by the system, so the suggestion clears the moment it's turned on.
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lowPower = LowPower.isEnabled(); self?.syncMenuBar() }
        }
    }

    // MARK: Storage

    /// Decodes saved history off the main thread so launch (and login) isn't blocked.
    private func loadHistory() {
        let file = self.file
        let cutoff = Date().timeIntervalSince1970 - keep
        Task {
            let (loaded, pruned) = await Task.detached(priority: .userInitiated) { () -> ([Sample], Bool) in
                guard let data = try? Data(contentsOf: file) else { return ([], false) }
                let dec = JSONDecoder()
                var out: [Sample] = []
                var all = 0
                for line in data.split(separator: 10) {
                    all += 1
                    if let s = try? dec.decode(Sample.self, from: line), s.t >= cutoff { out.append(s) }
                }
                return (out, out.count < all)
            }.value
            // Anything recorded while loading is newer; skip any that already made it into the file.
            let lastLoaded = loaded.last?.t ?? 0
            samples = loaded + samples.filter { $0.t > lastLoaded }
            if pruned { rewriteFile() }
        }
    }

    private func rewriteFile() {
        let snapshot = samples, file = self.file
        io.async {
            let enc = JSONEncoder()
            var out = Data()
            for s in snapshot {
                guard let d = try? enc.encode(s) else { continue }
                out.append(d); out.append(10)
            }
            try? out.write(to: file, options: .atomic)
        }
    }

    private func append(_ s: Sample) {
        let file = self.file
        io.async {
            guard var data = try? JSONEncoder().encode(s) else { return }
            data.append(10)
            if let h = try? FileHandle(forWritingTo: file) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: file)
            }
        }
    }

    /// Drops history past the retention window while the app keeps running. Runs about once a
    /// day so the file isn't rewritten constantly.
    private func pruneIfNeeded() {
        let cutoff = Date().timeIntervalSince1970 - keep
        guard let first = samples.first, first.t < cutoff - 86400 else { return }
        samples.removeSubrange(..<startIndex(from: cutoff))
        rewriteFile()
    }

    // MARK: Sampling

    /// Only publishes when a reading actually changed, so idle refreshes don't redraw anything.
    private func refreshPower() {
        let b = Sampler.battery()
        if b != battery { battery = b }
        let h = HealthReader.read()
        if h != health { health = h }
        syncMenuBar()
    }

    /// Updates the menu bar icon's inputs, publishing only real changes.
    func syncMenuBar() {
        let status = MenuBarStatus.shared
        let suggesting = lowPowerSuggestion != nil
        if status.suggesting != suggesting { status.suggesting = suggesting }
        let fw = health?.systemWatts
        if status.fallbackWatts.map(wattsText) != fw.map(wattsText) { status.fallbackWatts = fw }
    }

    private func record(_ rows: [Int32: Double]) {
        let (apps, paths) = Sampler.identify(rows)
        let b = Sampler.battery()
        battery = b
        health = HealthReader.read()
        lowPower = LowPower.isEnabled()
        guard !apps.isEmpty else { return }

        // Keep the 12 heaviest apps per sample to bound storage.
        var a: [String: Double] = [:]
        for (k, v) in apps.sorted(by: { $0.value > $1.value }).prefix(12) { a[k] = (v * 10).rounded() / 10 }

        let s = Sample(t: Date().timeIntervalSince1970, b: b.percent, ac: b.pluggedIn, a: a)
        samples.append(s)
        append(s)

        if paths.contains(where: { appPaths[$0.key] != $0.value }) {
            appPaths.merge(paths) { _, new in new }
            let snapshot = appPaths, pathsFile = self.pathsFile
            io.async { if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: pathsFile) } }
        }
        Alerts.shared.evaluate(samples: samples, battery: b, appPaths: appPaths)
        pruneIfNeeded()
        syncMenuBar()
    }

    // MARK: Queries

    /// Index of the first sample at or after `t` (samples are kept in time order).
    func startIndex(from t: Double) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func window(since t: Double) -> ArraySlice<Sample> { samples[startIndex(from: t)...] }

    /// Returns the cached value for `key`, computing it only if the data changed since last time.
    /// With `maxAge`, a value is also reused for that many seconds after new samples arrive: the
    /// week and month views would otherwise rescan their whole range on every 30 s sample.
    func memo<T>(_ key: String, maxAge: Double = 0, _ make: () -> T) -> T {
        let now = Date().timeIntervalSince1970
        if cacheVersion != version {
            cache = cache.filter { now - $0.value.at < $0.value.maxAge }
            cacheVersion = version
        }
        if let e = cache[key], let v = e.value as? T, e.version == version || now - e.at < e.maxAge { return v }
        let v = make()
        cache[key] = CacheEntry(version: version, at: now, maxAge: maxAge, value: v)
        return v
    }

    /// Suggests Low Power Mode when on battery and it's off, using the user's limits: battery at or
    /// below the "usage" level while drawing at least the chosen watts, or at or below the critical level.
    /// The app never changes the setting itself.
    var lowPowerSuggestion: String? {
        let st = Settings.shared
        guard st.lpmSuggest, battery.hasBattery, !battery.pluggedIn, !lowPower else { return nil }
        let pctText = "\(Int(battery.percent.rounded()))%"
        if battery.percent <= Double(st.lpmCritical) { return "Battery is at \(pctText)." }
        if battery.percent <= Double(st.lpmPercent) {
            let w = LiveWatts.shared.watts ?? health?.systemWatts ?? 0
            if st.lpmWatts == 0 { return "Battery is at \(pctText)." }
            if w >= Double(st.lpmWatts) { return "Battery is at \(pctText) and your Mac is using \(String(format: "%.0f", w)) W." }
        }
        return nil
    }

    func analyze(range: TimeRange, onlyOnBattery: Bool, appsOnly: Bool = false) -> Analysis {
        memo("analyze|\(range.rawValue)|\(onlyOnBattery)|\(appsOnly)", maxAge: range.cacheAge) {
            let now = Date().timeIntervalSince1970
            let s = window(since: now - range.seconds).filter { !onlyOnBattery || !$0.ac }
            return Tracker.analysis(of: s, appPaths: appPaths, appsOnly: appsOnly, now: now)
        }
    }

    /// Splits `first...now` into up to 48 equal buckets. When a bucket is wider than two sample
    /// intervals, an empty one means the Mac was asleep (or the range was filtered out), so charts
    /// draw it as zero instead of a line straight across. Narrower empty buckets are just
    /// rounding (30 s samples landing unevenly) and are skipped.
    nonisolated static func buckets(first: Double, now: Double, count: Int) -> (count: Int, len: Double, fillGaps: Bool) {
        let n = max(2, min(48, count))
        let len = max(1, now - first) / Double(n)
        return (n, len, len > 2 * Double(interval))
    }

    /// Rankings and chart series for a set of samples. Pure, so it can be tested directly.
    nonisolated static func analysis(of s: [Sample], appPaths: [String: String], appsOnly: Bool, now: Double) -> Analysis {
        var out = Analysis()
        out.sampleCount = s.count
        guard let first = s.first else { return out }

        var totals: [String: Double] = [:]
        for x in s { for (k, v) in x.a where !appsOnly || appPaths[k] != nil { totals[k, default: 0] += v } }
        let grand = totals.values.reduce(0, +)
        guard grand > 0 else { return out }
        out.ranked = totals.sorted { $0.value > $1.value }.map { RankedApp(name: $0.key, share: $0.value / grand) }

        let topNames = Array(out.ranked.prefix(5).map(\.name))
        let topSet = Set(topNames)
        out.seriesNames = topNames + (out.ranked.count > 5 ? ["Other"] : [])

        // Bucket into ~48 slices, averaging energy impact within each.
        // Span only the data we have, so young histories still draw.
        let start = first.t
        let (buckets, len, fillGaps) = Tracker.buckets(first: start, now: now, count: s.count)
        var sums = [[String: Double]](repeating: [:], count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        for x in s {
            let i = min(buckets - 1, max(0, Int((x.t - start) / len)))
            counts[i] += 1
            for (k, v) in x.a where !appsOnly || appPaths[k] != nil { sums[i][topSet.contains(k) ? k : "Other", default: 0] += v }
        }
        let last = counts.lastIndex { $0 > 0 } ?? 0
        for i in 0...last where counts[i] > 0 || fillGaps {
            let d = Date(timeIntervalSince1970: start + (Double(i) + 0.5) * len)
            for n in out.seriesNames {
                let v = counts[i] > 0 ? (sums[i][n] ?? 0) / Double(counts[i]) : 0
                out.series.append(SeriesPoint(date: d, app: n, value: v))
            }
        }

        let stride = max(1, s.count / 300)
        out.battery = Swift.stride(from: 0, to: s.count, by: stride).map { (s[$0].date, s[$0].b) }
        return out
    }
}
