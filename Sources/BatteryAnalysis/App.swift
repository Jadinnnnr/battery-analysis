import SwiftUI
import UserNotifications

/// Whether the dashboard window is currently open (drives the menu bar icon color).
@MainActor
final class UIState: ObservableObject {
    static let shared = UIState()
    @Published var dashboardOpen = false
}

extension Notification.Name {
    static let showDashboard = Notification.Name("batteryanalysis.showDashboard")
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let background = CommandLine.arguments.contains("--background")

    // Keep sampling in the background after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        LaunchAtLogin.repairIfMoved()
        Task { @MainActor in
            Alerts.shared.registerCategories()
            LiveWatts.shared.configure()
            if Settings.shared.drainAlerts || Settings.shared.lowBatteryAlerts { Alerts.shared.requestAuth() }
        }

        // Menu-bar-first: the Dock icon exists only while the dashboard window is open.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, w.title == "Battery Analysis" else { return }
            Task { @MainActor in UIState.shared.dashboardOpen = true }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, w.title == "Battery Analysis" else { return }
            Task { @MainActor in UIState.shared.dashboardOpen = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { AppDelegate.goAccessory(closing: w) }
        }

        if background {
            // Launched at login: no window.
            NSApp.setActivationPolicy(.accessory)
            for delay in [0.15, 0.5, 1.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.hideDashboard() }
            }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Clicking the app in Finder/Spotlight while it runs in the menu bar reopens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: .showDashboard, object: nil) }
        return false
    }

    /// Drops the Dock icon once no dashboard window is left. macOS refuses the switch while
    /// the app is frontmost, so deactivate first and retry briefly.
    static func goAccessory(closing: NSWindow? = nil, attempt: Int = 0) {
        let stillOpen = NSApp.windows.contains { $0 !== closing && $0.title == "Battery Analysis" && $0.isVisible }
        if stillOpen { return }
        NSApp.deactivate()
        let ok = NSApp.setActivationPolicy(.accessory)
        if !ok && attempt < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { goAccessory(closing: closing, attempt: attempt + 1) }
        }
    }

    private func hideDashboard() {
        for w in NSApp.windows where w.title == "Battery Analysis" && w.styleMask.contains(.titled) { w.close() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == "QUIT",
              let name = response.notification.request.content.userInfo["name"] as? String,
              let path = response.notification.request.content.userInfo["path"] as? String, !path.isEmpty else { return }
        _ = Killer.quit(name: name, appPath: path, force: false)
    }
}

/// Menu bar icon. Lives as long as the app does, so it can reopen the dashboard on request.
/// Turns yellow when a Low Power Mode suggestion is waiting and the dashboard is closed.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var status = MenuBarStatus.shared
    @ObservedObject private var ui = UIState.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var live = LiveWatts.shared
    private var alert: Bool { status.suggesting && !ui.dashboardOpen }
    private var watts: Double? { settings.showWatts ? (live.watts ?? status.fallbackWatts) : nil }

    // Menu bar symbols are tinted by the system, so the yellow bolt is a real (non-template) image.
    private static let yellowBolt: NSImage = {
        let cfg = NSImage.SymbolConfiguration(paletteColors: [.systemYellow])
        let img = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Battery Analysis: suggestion")!
            .withSymbolConfiguration(cfg)!
        img.isTemplate = false
        return img
    }()

    var body: some View {
        HStack(spacing: 3) {
            if alert { Image(nsImage: Self.yellowBolt) } else { Image(systemName: "bolt.fill") }
            if let watts { Text(wattsText(watts)).monospacedDigit() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDashboard)) { _ in
            Task { @MainActor in showDashboard(openWindow) }
        }
    }
}

@main
struct BatteryAnalysisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    // Plain references, not @StateObject: the top level must not observe these, or every new
    // sample would rebuild every scene. Views that need updates observe what they use.
    private let tracker = Tracker.shared
    private let settings = Settings.shared

    var body: some Scene {
        Window("Battery Analysis", id: "main") {
            DashboardView()
                .frame(minWidth: 900, minHeight: 700)
            .environmentObject(tracker)
            .environmentObject(settings)
            .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 800)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(tracker)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// "6.8 W" below 10 W, "12 W" above, so the label stays about the same width.
func wattsText(_ w: Double) -> String {
    w < 10 ? String(format: "%.1f W", w) : "\(Int(w.rounded())) W"
}

func batterySymbol(_ b: BatteryInfo) -> String {
    if b.charging { return "battery.100percent.bolt" }
    switch b.percent {
    case 88...: return "battery.100percent"
    case 63...: return "battery.75percent"
    case 38...: return "battery.50percent"
    case 13...: return "battery.25percent"
    default: return "battery.0percent"
    }
}
