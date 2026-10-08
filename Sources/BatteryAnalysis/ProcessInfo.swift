import SwiftUI

enum Importance: String {
    case critical = "Critical", important = "Important", optional = "Optional"
    var color: Color {
        switch self {
        case .critical: Color(red: 1.0, green: 0.42, blue: 0.45)
        case .important: Color(red: 1.0, green: 0.71, blue: 0.37)
        case .optional: Color(red: 0.4, green: 0.82, blue: 0.65)
        }
    }
    var hint: String {
        switch self {
        case .critical: "macOS can't run without it"
        case .important: "Needed for a core feature"
        case .optional: "Safe to ignore or pause"
        }
    }
}

struct ProcessNote {
    let text: String
    let importance: Importance
}

enum ProcessCatalog {
    private static let known: [String: ProcessNote] = [
        "kernel_task": .init(text: "The macOS kernel. Also throttles the CPU when your Mac gets hot.", importance: .critical),
        "launchd": .init(text: "Starts and supervises every other process on your Mac.", importance: .critical),
        "WindowServer": .init(text: "Draws everything on screen. Works harder with more displays, animations or video.", importance: .critical),
        "loginwindow": .init(text: "Manages your login session and the lock screen.", importance: .critical),
        "Finder": .init(text: "The desktop and file browser.", importance: .critical),
        "Dock": .init(text: "The Dock, Mission Control and app switching.", importance: .critical),
        "SystemUIServer": .init(text: "Runs menu bar items like Wi-Fi, clock and battery.", importance: .critical),
        "ControlCenter": .init(text: "The Control Center menu and menu bar status icons.", importance: .important),
        "NotificationCenter": .init(text: "Shows notifications and widgets.", importance: .important),
        "coreaudiod": .init(text: "Handles all sound input and output.", importance: .critical),
        "bluetoothd": .init(text: "Manages Bluetooth devices like AirPods and keyboards.", importance: .important),
        "airportd": .init(text: "Manages Wi-Fi connections.", importance: .critical),
        "configd": .init(text: "Tracks network settings and connectivity changes.", importance: .critical),
        "powerd": .init(text: "Manages sleep, wake and power settings.", importance: .critical),
        "thermalmonitord": .init(text: "Watches temperatures and protects the hardware from overheating.", importance: .critical),
        "hidd": .init(text: "Reads your keyboard, mouse and trackpad input.", importance: .critical),
        "distnoted": .init(text: "Passes notifications between apps and the system.", importance: .critical),
        "cfprefsd": .init(text: "Reads and saves app and system preferences.", importance: .critical),
        "securityd": .init(text: "Keychain and security services.", importance: .critical),
        "trustd": .init(text: "Verifies certificates and app signatures.", importance: .critical),
        "syspolicyd": .init(text: "Gatekeeper: checks apps are safe to open.", importance: .critical),
        "amfid": .init(text: "Verifies app code signatures.", importance: .critical),
        "opendirectoryd": .init(text: "User accounts and login directory.", importance: .critical),
        "diskarbitrationd": .init(text: "Mounts and unmounts drives.", importance: .critical),
        "fseventsd": .init(text: "Tells apps and Spotlight when files change.", importance: .critical),
        "logd": .init(text: "Collects system logs.", importance: .critical),
        "mds": .init(text: "Spotlight indexing coordinator. Busy after big file changes or updates.", importance: .important),
        "mds_stores": .init(text: "Spotlight search index. Heavy right after installs and updates.", importance: .important),
        "mdworker_shared": .init(text: "Spotlight workers that read files to build the search index.", importance: .optional),
        "mdworker": .init(text: "Spotlight workers that read files to build the search index.", importance: .optional),
        "corespotlightd": .init(text: "Indexes app content (messages, notes) for Spotlight.", importance: .optional),
        "spotlightknowledged": .init(text: "Spotlight suggestions and knowledge.", importance: .optional),
        "spotlightknowledged.updater": .init(text: "Updates Spotlight suggestion data in the background.", importance: .optional),
        "backupd": .init(text: "Time Machine backups. Drains battery while a backup runs.", importance: .optional),
        "Time Machine": .init(text: "Time Machine backups.", importance: .optional),
        "photoanalysisd": .init(text: "Scans your Photos library for faces, objects and memories.", importance: .optional),
        "photolibraryd": .init(text: "Manages your Photos library.", importance: .important),
        "mediaanalysisd": .init(text: "Analyzes photos and videos (Visual Look Up, search). Can be heavy.", importance: .optional),
        "cloudd": .init(text: "iCloud sync. Busy when uploading or downloading files.", importance: .important),
        "bird": .init(text: "iCloud Drive file syncing.", importance: .important),
        "nsurlsessiond": .init(text: "Downloads and uploads files for apps in the background.", importance: .important),
        "apsd": .init(text: "Apple push notifications service.", importance: .important),
        "appstoreagent": .init(text: "Downloads and installs App Store updates in the background.", importance: .optional),
        "softwareupdated": .init(text: "Checks for and downloads macOS updates.", importance: .optional),
        "mobileassetd": .init(text: "Downloads system assets such as fonts, dictionaries and AI models.", importance: .optional),
        "accountsd": .init(text: "Manages your signed-in accounts.", importance: .important),
        "identityservicesd": .init(text: "Powers iMessage and FaceTime sign-in.", importance: .important),
        "imagent": .init(text: "Background helper for Messages.", importance: .important),
        "suggestd": .init(text: "Siri suggestions across apps.", importance: .optional),
        "siriactionsd": .init(text: "Runs Siri and Shortcuts actions.", importance: .optional),
        "assistantd": .init(text: "Siri background service.", importance: .optional),
        "assistant_service": .init(text: "Siri background service.", importance: .optional),
        "BackgroundShortcutRunner": .init(text: "Runs Shortcuts automations in the background.", importance: .optional),
        "axassetsd": .init(text: "Downloads accessibility assets such as voices.", importance: .optional),
        "linkd": .init(text: "Connects app actions to Shortcuts and Siri.", importance: .optional),
        "knowledge-agent": .init(text: "Builds on-device knowledge for Siri suggestions.", importance: .optional),
        "biomed": .init(text: "Stores on-device usage patterns for suggestions.", importance: .optional),
        "triald": .init(text: "Runs Apple feature experiments and tests.", importance: .optional),
        "analyticsd": .init(text: "Collects anonymous diagnostics and usage data.", importance: .optional),
        "diagnosticd": .init(text: "Collects diagnostic data.", importance: .optional),
        "ReportCrash": .init(text: "Writes crash reports after an app crashes.", importance: .optional),
        "WiFiAgent": .init(text: "The Wi-Fi menu and network prompts.", importance: .important),
        "sharingd": .init(text: "AirDrop, Handoff and sharing between devices.", importance: .optional),
        "rapportd": .init(text: "Connects your Mac to nearby Apple devices (Handoff, Continuity).", importance: .optional),
        "remoted": .init(text: "Talks to nearby devices and accessories.", importance: .optional),
        "universalaccessd": .init(text: "Accessibility features.", importance: .important),
        "TextInputMenuAgent": .init(text: "The keyboard and input-language menu.", importance: .important),
        "pbs": .init(text: "Services menu and text-input helpers.", importance: .important),
        "usernoted": .init(text: "Delivers notifications to you.", importance: .important),
        "locationd": .init(text: "Location services for apps and the system.", importance: .important),
        "timed": .init(text: "Keeps the clock in sync.", importance: .important),
        "UserEventAgent": .init(text: "Watches system events and triggers background tasks.", importance: .critical),
        "runningboardd": .init(text: "Decides which apps may run and how much resource they get.", importance: .critical),
        "dasd": .init(text: "Schedules background tasks to run at efficient times.", importance: .important),
        "duetexpertd": .init(text: "Learns your habits to schedule work and predictions.", importance: .optional),
        "contextstored": .init(text: "Stores context for system predictions.", importance: .optional),
        "WeatherWidget": .init(text: "Weather widget refresh.", importance: .optional),
        "ThemeWidgetControlViewService": .init(text: "Widget and appearance helper.", importance: .optional),
        "com.apple.DriverKit-AppleBCMWLAN": .init(text: "Wi-Fi chip driver.", importance: .critical),
        "screencaptureui": .init(text: "Screenshot and screen-recording tool.", importance: .optional),
        "coreduetd": .init(text: "Learns usage patterns to optimize battery and scheduling.", importance: .important),
        "tccd": .init(text: "Enforces app privacy permissions (camera, mic, files).", importance: .critical),
        "lsd": .init(text: "Tracks which apps open which file types.", importance: .critical),
        "nsattributedstringagent": .init(text: "Text-rendering helper.", importance: .important),
        "com.apple.WebKit.WebContent": .init(text: "Renders web content inside apps and Safari.", importance: .important),
        "com.apple.WebKit.Networking": .init(text: "Network helper for Safari and web views.", importance: .important),
        "com.apple.WebKit.GPU": .init(text: "Graphics helper for web content.", importance: .important),
    ]

    /// Description for system-level processes. Returns nil for regular apps.
    static func note(for name: String, isApp: Bool) -> ProcessNote? {
        if isApp { return nil }
        if let n = known[name] { return n }
        if name.hasPrefix("com.apple.") {
            return .init(text: "An Apple system extension or helper (\(name.replacingOccurrences(of: "com.apple.", with: ""))).", importance: .important)
        }
        if name.hasSuffix("d") || name.hasSuffix("agent") || name.hasSuffix("Agent") {
            return .init(text: "A background macOS service. Not something you need to manage directly.", importance: .important)
        }
        return .init(text: "A background process with no known description.", importance: .important)
    }
}

struct ImportanceBadge: View {
    let importance: Importance
    var body: some View {
        Text(importance.rawValue)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(importance.color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(importance.color.opacity(0.15)))
            .help(importance.hint)
    }
}
