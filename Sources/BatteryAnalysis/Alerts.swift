import Foundation
import UserNotifications

@MainActor
final class Alerts {
    static let shared = Alerts()
    private var lastDrain: [String: Date] = [:]
    private var lowBatteryNotified = false
    private var center: UNUserNotificationCenter { .current() }

    func registerCategories() {
        let quit = UNNotificationAction(identifier: "QUIT", title: "Quit it", options: [])
        // "Quit it" is offered only for real apps (see `post`); background processes get no action.
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "DRAIN", actions: [quit], intentIdentifiers: []),
            UNNotificationCategory(identifier: "LOWBATT", actions: [quit], intentIdentifiers: []),
            UNNotificationCategory(identifier: "INFO", actions: [], intentIdentifiers: []),
        ])
    }

    func requestAuth() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func post(_ title: String, _ body: String, category: String, name: String?, path: String?) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        // Quitting from a notification skips the confirmation dialog, so it's limited to apps:
        // they get a normal Quit request, never a signal sent to every process with that name.
        if let name, let path {
            c.categoryIdentifier = category
            c.userInfo = ["name": name, "path": path]
        } else {
            c.categoryIdentifier = "INFO"
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// Heaviest recent app that is safe to quit (not critical to macOS, not us).
    static func topDrainer(samples: [Sample], appPaths: [String: String], window: Double = 600) -> (name: String, avg: Double, share: Double)? {
        let cutoff = Date().timeIntervalSince1970 - window
        let recent = samples.suffix(60).filter { $0.t >= cutoff }
        guard recent.count >= 4 else { return nil }
        var totals: [String: Double] = [:]
        for s in recent { for (k, v) in s.a { totals[k, default: 0] += v } }
        let grand = totals.values.reduce(0, +)
        guard grand > 0 else { return nil }
        for (name, sum) in totals.sorted(by: { $0.value > $1.value }) {
            if name == "BatteryAnalysis" { continue }
            if ProcessCatalog.note(for: name, isApp: appPaths[name] != nil)?.importance == .critical { continue }
            return (name, sum / Double(recent.count), sum / grand)
        }
        return nil
    }

    func evaluate(samples: [Sample], battery: BatteryInfo, appPaths: [String: String]) {
        let settings = Settings.shared
        if battery.pluggedIn || battery.percent > Double(settings.lowBatteryPercent + 10) { lowBatteryNotified = false }
        guard battery.hasBattery, !battery.pluggedIn else { return }
        let drainer = Alerts.topDrainer(samples: samples, appPaths: appPaths)

        if settings.lowBatteryAlerts, battery.percent <= Double(settings.lowBatteryPercent), !lowBatteryNotified {
            lowBatteryNotified = true
            var body = "Consider turning on Low Power Mode in System Settings › Battery."
            if let d = drainer { body = "\(d.name) is your biggest drain right now. " + body }
            post("Battery at \(Int(battery.percent.rounded()))%", body, category: "LOWBATT",
                 name: drainer?.name, path: drainer.flatMap { appPaths[$0.name] })
        }

        if settings.drainAlerts, let d = drainer, d.avg >= 25, d.share >= 0.4 {
            if let last = lastDrain[d.name], Date().timeIntervalSince(last) < 3 * 3600 { return }
            lastDrain[d.name] = Date()
            let note = ProcessCatalog.note(for: d.name, isApp: appPaths[d.name] != nil)
            var body = "It has used \(Int((d.share * 100).rounded()))% of your energy over the last 10 minutes."
            if let n = note { body += " \(n.text)" }
            post("\(d.name) is draining your battery", body, category: "DRAIN", name: d.name, path: appPaths[d.name])
        }
    }
}
