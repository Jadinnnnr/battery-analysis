import Foundation

struct AppHistory {
    var points: [(date: Date, value: Double)] = []
    var average = 0.0
    var trend: Double? = nil                       // change in avg energy, newer half vs older half
    var daily: [(day: Date, share: Double)] = []
}

struct ModeShare: Identifiable {
    var id: String { app + "|" + mode }
    let app: String
    let mode: String
    let share: Double
}

struct WeeklySummary {
    var thisWeek: [RankedApp] = []
    var lastWeek: [String: Double] = [:]
    var hasLast = false
}

extension Tracker {
    func shares<C: Collection>(_ s: C, appsOnly: Bool) -> [String: Double] where C.Element == Sample {
        var totals: [String: Double] = [:]
        for x in s { for (k, v) in x.a where !appsOnly || appPaths[k] != nil { totals[k, default: 0] += v } }
        let grand = totals.values.reduce(0, +)
        guard grand > 0 else { return [:] }
        return totals.mapValues { $0 / grand }
    }

    func history(for name: String, range: TimeRange, onlyOnBattery: Bool) -> AppHistory {
        memo("history|\(name)|\(range.rawValue)|\(onlyOnBattery)") { computeHistory(for: name, range: range, onlyOnBattery: onlyOnBattery) }
    }

    private func computeHistory(for name: String, range: TimeRange, onlyOnBattery: Bool) -> AppHistory {
        let now = Date().timeIntervalSince1970
        let s = window(since: now - range.seconds).filter { !onlyOnBattery || !$0.ac }
        var h = AppHistory()
        if let first = s.first {
            let span = max(1, now - first.t)
            let buckets = max(2, min(48, s.count))
            let len = span / Double(buckets)
            var sums = [Double](repeating: 0, count: buckets)
            var counts = [Int](repeating: 0, count: buckets)
            for x in s {
                let i = min(buckets - 1, max(0, Int((x.t - first.t) / len)))
                counts[i] += 1; sums[i] += x.a[name] ?? 0
            }
            for i in 0..<buckets where counts[i] > 0 {
                h.points.append((Date(timeIntervalSince1970: first.t + (Double(i) + 0.5) * len), sums[i] / Double(counts[i])))
            }
            h.average = s.map { $0.a[name] ?? 0 }.reduce(0, +) / Double(s.count)
            let mid = s.count / 2
            if mid >= 10, s.count - mid >= 10 {
                let older = s[..<mid].map { $0.a[name] ?? 0 }.reduce(0, +) / Double(mid)
                let newer = s[mid...].map { $0.a[name] ?? 0 }.reduce(0, +) / Double(s.count - mid)
                if older > 1 { h.trend = (newer - older) / older }
            }
        }
        // Daily share over the last 14 days, independent of the range picker.
        let cal = Calendar.current
        var perDay: [Date: (app: Double, total: Double)] = [:]
        for x in window(since: now - 14 * 86400) {
            let day = cal.startOfDay(for: x.date)
            var e = perDay[day] ?? (0, 0)
            e.app += x.a[name] ?? 0
            e.total += x.a.values.reduce(0, +)
            perDay[day] = e
        }
        h.daily = perDay.filter { $0.value.total > 0 }.map { ($0.key, $0.value.app / $0.value.total) }.sorted { $0.0 < $1.0 }
        return h
    }

    func compareModes(range: TimeRange, appsOnly: Bool) -> [ModeShare] {
        memo("compare|\(range.rawValue)|\(appsOnly)") { computeCompare(range: range, appsOnly: appsOnly) }
    }

    private func computeCompare(range: TimeRange, appsOnly: Bool) -> [ModeShare] {
        let now = Date().timeIntervalSince1970
        let s = window(since: now - range.seconds)
        let on = s.filter { !$0.ac }, off = s.filter { $0.ac }
        guard on.count >= 10, off.count >= 10 else { return [] }
        let a = shares(on, appsOnly: appsOnly), b = shares(off, appsOnly: appsOnly)
        let top = a.sorted { $0.value > $1.value }.prefix(6).map(\.key)
        return top.flatMap { app in
            [ModeShare(app: app, mode: "On battery", share: a[app] ?? 0),
             ModeShare(app: app, mode: "Plugged in", share: b[app] ?? 0)]
        }
    }

    func weekly(appsOnly: Bool) -> WeeklySummary {
        memo("weekly|\(appsOnly)") { computeWeekly(appsOnly: appsOnly) }
    }

    private func computeWeekly(appsOnly: Bool) -> WeeklySummary {
        let now = Date().timeIntervalSince1970
        let week = 7 * 86400.0
        let split = startIndex(from: now - week)
        let this = samples[split...]
        let last = samples[startIndex(from: now - 2 * week)..<split]
        var w = WeeklySummary()
        w.thisWeek = shares(this, appsOnly: appsOnly).sorted { $0.value > $1.value }.map { RankedApp(name: $0.key, share: $0.value) }
        if last.count >= 200 { w.lastWeek = shares(last, appsOnly: appsOnly); w.hasLast = true }
        return w
    }

    func csv(range: TimeRange) -> String {
        let now = Date().timeIntervalSince1970
        let iso = ISO8601DateFormatter()
        var out = "timestamp,battery_percent,plugged_in,app,energy_impact\n"
        for s in window(since: now - range.seconds) {
            for (app, v) in s.a.sorted(by: { $0.key < $1.key }) {
                let q = "\"" + app.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                out += "\(iso.string(from: s.date)),\(Int(s.b)),\(s.ac),\(q),\(v)\n"
            }
        }
        return out
    }
}
