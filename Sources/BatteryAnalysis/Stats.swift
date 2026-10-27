import AppKit
import Foundation

/// The periods the Stats tab can total.
enum StatsPeriod: String, CaseIterable, Identifiable {
    case today = "Today", week = "7 days", month = "30 days", all = "All time"
    var id: String { rawValue }

    /// Calendar days covered, counting today; nil for all time.
    var days: Int? {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .all: nil
        }
    }
}

/// Running energy totals in watt-hours, one entry per local calendar day. A plain value type so
/// the arithmetic can be tested on its own; `EnergyStats` feeds it readings and saves it.
struct EnergyLedger: Codable, Equatable {
    struct Day: Codable, Equatable {
        var mac = 0.0          // what the Mac used, connected devices included
        var appsPool = 0.0     // the Mac's own share, not yet split between apps
        var inflow = 0.0       // in from chargers
        var battery = 0.0      // into the battery
        var apps: [String: Double] = [:]
        var devices: [String: Double] = [:]
        var chargers: [String: Double] = [:]
        var seconds = 0.0      // awake time counted
        var peakIn = 0.0       // highest charger input seen, in watts
    }

    var since: Double
    var days: [String: Day] = [:]
    /// Icon for each device seen, so past devices keep theirs after they're unplugged.
    var deviceSymbols: [String: String] = [:]

    init(since: Double) { self.since = since }

    /// Readings arrive every 10 s while the Mac is awake. A longer gap means it slept or the app
    /// wasn't running; that time isn't counted rather than guessed.
    static let maxGap: Double = 60

    static func slice(dt: Double) -> Double? { dt > 0 && dt <= maxGap ? dt : nil }

    static func dayKey(_ t: Double, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: t))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Adds `dt` seconds at the given readings (watts) to the day containing `t`.
    mutating func add(at t: Double, dt: Double, mac: Double, inflow: Double?, battery: Double?,
                      devices: [String: Double], charger: String?, calendar: Calendar = .current) {
        guard let dt = Self.slice(dt: dt) else { return }
        let hours = dt / 3600
        let key = Self.dayKey(t, calendar: calendar)
        var d = days[key] ?? Day()
        let m = max(0, mac)
        let out = devices.values.reduce(0) { $0 + max(0, $1) }
        d.mac += m * hours
        // The Mac's total includes what its ports supply; that part isn't any app's.
        d.appsPool += max(0, m - out) * hours
        for (name, w) in devices where w > 0 { d.devices[name, default: 0] += w * hours }
        if let inflow, inflow > 0 {
            d.inflow += inflow * hours
            d.chargers[charger ?? "Charger", default: 0] += inflow * hours
            d.peakIn = max(d.peakIn, inflow)
        }
        if let battery, battery > 0 { d.battery += battery * hours }
        d.seconds += dt
        days[key] = d
    }

    /// Splits the energy waiting for apps by each process's share of a sample's Energy Impact.
    /// Every day with some waiting is settled, so energy from just before midnight lands on the
    /// day it was used.
    mutating func attributeApps(impacts: [String: Double]) {
        let total = impacts.values.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return }
        for (key, var d) in days where d.appsPool > 0 {
            for (name, v) in impacts where v > 0 { d.apps[name, default: 0] += d.appsPool * v / total }
            d.appsPool = 0
            days[key] = d
        }
    }

    struct Totals: Equatable {
        var mac = 0.0, inflow = 0.0, battery = 0.0, seconds = 0.0
        var apps: [String: Double] = [:]
        var devices: [String: Double] = [:]
        var chargers: [String: Double] = [:]
        var outflow: Double { devices.values.reduce(0, +) }
        var appsTotal: Double { apps.values.reduce(0, +) }
    }

    func totals(for period: StatsPeriod, now: Double, calendar: Calendar = .current) -> Totals {
        var keys: Set<String>?
        if let n = period.days {
            let today = Date(timeIntervalSince1970: now)
            keys = Set((0..<n).compactMap { i in
                calendar.date(byAdding: .day, value: -i, to: today).map { Self.dayKey($0.timeIntervalSince1970, calendar: calendar) }
            })
        }
        var t = Totals()
        for (key, d) in days where keys?.contains(key) ?? true {
            t.mac += d.mac; t.inflow += d.inflow; t.battery += d.battery; t.seconds += d.seconds
            t.apps.merge(d.apps, uniquingKeysWith: +)
            t.devices.merge(d.devices, uniquingKeysWith: +)
            t.chargers.merge(d.chargers, uniquingKeysWith: +)
        }
        return t
    }

    struct Records {
        var biggestDay: (day: String, wh: Double)?
        var peakCharging: (day: String, watts: Double)?
        var hungriestApp: (day: String, app: String, wh: Double)?
    }

    /// All-time bests, independent of the period shown.
    var records: Records {
        var r = Records()
        for (key, d) in days {
            if d.mac > 0, d.mac > (r.biggestDay?.wh ?? 0) { r.biggestDay = (key, d.mac) }
            if d.peakIn > 0, d.peakIn > (r.peakCharging?.watts ?? 0) { r.peakCharging = (key, d.peakIn) }
            if let top = d.apps.max(by: { $0.value < $1.value }), top.value > (r.hungriestApp?.wh ?? 0) {
                r.hungriestApp = (key, top.key, top.value)
            }
        }
        return r
    }

    /// The date a day key stands for, for display.
    static func date(fromKey key: String, calendar: Calendar = .current) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

/// "742 Wh" up to a kilowatt-hour, then "1.24 kWh".
func energyText(_ wh: Double) -> String {
    if wh >= 1000 { return String(format: "%.2f kWh", wh / 1000) }
    if wh >= 10 { return "\(Int(wh.rounded())) Wh" }
    return String(format: "%.1f Wh", wh)
}

/// The app's running energy totals, saved to stats.json next to the history. Separate from
/// Tracker so only the Stats tab redraws when they change.
@MainActor
final class EnergyStats: ObservableObject {
    static let shared = EnergyStats()
    @Published private(set) var ledger: EnergyLedger

    /// Rough sizes for the "for fun" comparisons.
    static let iPhoneChargeWh = 13.0   // a recent iPhone battery
    static let bulbWatts = 10.0        // an LED bulb

    private let file: URL
    private let io = DispatchQueue(label: "batteryanalysis.stats", qos: .utility)
    private var lastReading: Double?
    private var lastSave = Date().timeIntervalSince1970
    private static let saveEvery: Double = 300

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BatteryAnalysis")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("stats.json")
        if let data = try? Data(contentsOf: file) {
            if let l = try? JSONDecoder().decode(EnergyLedger.self, from: data) {
                ledger = l
            } else {
                // Keep an unreadable file instead of overwriting it with fresh totals.
                try? FileManager.default.moveItem(at: file, to: dir.appendingPathComponent("stats-unreadable-\(Int(Date().timeIntervalSince1970)).json"))
                ledger = EnergyLedger(since: Date().timeIntervalSince1970)
            }
        } else {
            ledger = EnergyLedger(since: Date().timeIntervalSince1970)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { EnergyStats.shared.save(waiting: true) }
        }
    }

    /// Called by Tracker every 10 s with the latest readings, in watts.
    func record(mac: Double?, inflow: Double?, battery: Double?, devices: [ConnectedDevice], charger: String?) {
        let now = Date().timeIntervalSince1970
        defer { lastReading = now }
        guard let last = lastReading, let mac else { return }
        var l = ledger
        var deviceWatts: [String: Double] = [:]
        for d in devices {
            deviceWatts[d.name, default: 0] += d.watts
            l.deviceSymbols[d.name] = d.kind.symbol
        }
        l.add(at: now, dt: now - last, mac: mac, inflow: inflow, battery: battery, devices: deviceWatts, charger: charger)
        ledger = l
        if now - lastSave >= Self.saveEvery { save() }
    }

    /// Called by Tracker with each 30 s sample's Energy Impact per process.
    func attributeApps(_ impacts: [String: Double]) {
        var l = ledger
        l.attributeApps(impacts: impacts)
        if l != ledger { ledger = l }
    }

    func reset() {
        ledger = EnergyLedger(since: Date().timeIntervalSince1970)
        save()
    }

    /// Writes off the main thread; on quit, waits so the write finishes before the app exits.
    private func save(waiting: Bool = false) {
        lastSave = Date().timeIntervalSince1970
        let snapshot = ledger, file = self.file
        let work: @Sendable () -> Void = { if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: file, options: .atomic) } }
        if waiting { io.sync(execute: work) } else { io.async(execute: work) }
    }
}
