import Foundation

/// Starts the app at login in the background (no window) via a per-user LaunchAgent.
enum LaunchAtLogin {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.batteryanalysis.login.plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The agent stores an absolute path, so moving or reinstalling the app elsewhere would leave
    /// it pointing at nothing. Called at launch: if the saved path is gone, point it at this copy.
    /// A path that still exists is left alone, so running a second copy (say, a fresh build in the
    /// project folder) doesn't take over the login item from the installed one.
    static func repairIfMoved() {
        guard isEnabled,
              let plist = NSDictionary(contentsOf: url),
              let saved = (plist["ProgramArguments"] as? [String])?.first,
              !FileManager.default.fileExists(atPath: saved),
              Bundle.main.executablePath != saved else { return }
        set(true)
    }

    static func set(_ on: Bool) {
        if on {
            guard let exe = Bundle.main.executablePath else { return }
            let plist: [String: Any] = [
                "Label": "local.batteryanalysis.login",
                "ProgramArguments": [exe, "--background"],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: url, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var launchAtLogin: Bool { didSet { LaunchAtLogin.set(launchAtLogin) } }
    @Published var drainAlerts: Bool {
        didSet { d.set(drainAlerts, forKey: "drainAlerts"); if drainAlerts { Alerts.shared.requestAuth() } }
    }
    @Published var lowBatteryAlerts: Bool {
        didSet { d.set(lowBatteryAlerts, forKey: "lowBatteryAlerts"); if lowBatteryAlerts { Alerts.shared.requestAuth() } }
    }

    // Low Power Mode suggestion limits (and the low-battery alert level), saved between launches.
    static let defaultLimits = (percent: 30, watts: 8, critical: 15, lowBattery: 20)
    @Published var showWatts: Bool { didSet { d.set(showWatts, forKey: "showWatts"); LiveWatts.shared.configure() } }
    static let wattsIntervals = [2, 5, 10]
    @Published var wattsInterval: Int { didSet { d.set(wattsInterval, forKey: "wattsInterval"); LiveWatts.shared.configure() } }
    @Published var lpmSuggest: Bool { didSet { d.set(lpmSuggest, forKey: "lpmSuggest"); Tracker.shared.syncMenuBar() } }
    @Published var lpmPercent: Int { didSet { d.set(lpmPercent, forKey: "lpmPercent"); Tracker.shared.syncMenuBar() } }
    @Published var lpmWatts: Int { didSet { d.set(lpmWatts, forKey: "lpmWatts"); Tracker.shared.syncMenuBar() } }
    @Published var lpmCritical: Int { didSet { d.set(lpmCritical, forKey: "lpmCritical"); Tracker.shared.syncMenuBar() } }
    @Published var lowBatteryPercent: Int { didSet { d.set(lowBatteryPercent, forKey: "lowBatteryPercent") } }

    func resetLimits() {
        let l = Settings.defaultLimits
        lpmPercent = l.percent; lpmWatts = l.watts; lpmCritical = l.critical; lowBatteryPercent = l.lowBattery
    }

    private init() {
        launchAtLogin = LaunchAtLogin.isEnabled
        let l = Settings.defaultLimits
        lpmSuggest = d.object(forKey: "lpmSuggest") as? Bool ?? true
        showWatts = d.object(forKey: "showWatts") as? Bool ?? true
        let savedInterval = d.object(forKey: "wattsInterval") as? Int ?? 5
        wattsInterval = Settings.wattsIntervals.contains(savedInterval) ? savedInterval : 5
        lpmPercent = d.object(forKey: "lpmPercent") as? Int ?? l.percent
        lpmWatts = d.object(forKey: "lpmWatts") as? Int ?? l.watts
        lpmCritical = d.object(forKey: "lpmCritical") as? Int ?? l.critical
        lowBatteryPercent = d.object(forKey: "lowBatteryPercent") as? Int ?? l.lowBattery
        drainAlerts = d.object(forKey: "drainAlerts") as? Bool ?? true
        lowBatteryAlerts = d.object(forKey: "lowBatteryAlerts") as? Bool ?? true
    }
}
