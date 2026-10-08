import SwiftUI
import Charts
import UniformTypeIdentifiers

enum Palette {
    static let accents: [Color] = [
        Color(red: 0.37, green: 0.61, blue: 1.00),
        Color(red: 0.69, green: 0.49, blue: 1.00),
        Color(red: 1.00, green: 0.48, blue: 0.66),
        Color(red: 1.00, green: 0.71, blue: 0.37),
        Color(red: 0.31, green: 0.82, blue: 0.65),
    ]
    static let other = Color.white.opacity(0.28)
    static let popover = Color(red: 0.09, green: 0.10, blue: 0.14)
    static let warning = Color(red: 1.0, green: 0.82, blue: 0.2)
    static let axis = Color.white.opacity(0.5)   // explicit: charts otherwise tint axis labels blue

    static func color(for name: String, in a: Analysis) -> Color {
        if name == "Other" { return other }
        if let i = a.ranked.prefix(5).firstIndex(where: { $0.name == name }) { return accents[i] }
        return other
    }

    static func level(_ p: Double, charging: Bool) -> Color {
        if charging { return Color(red: 0.31, green: 0.82, blue: 0.55) }
        return p > 50 ? Color(red: 0.31, green: 0.82, blue: 0.55) : p > 20 ? Color(red: 1.0, green: 0.71, blue: 0.3) : Color(red: 1.0, green: 0.37, blue: 0.4)
    }
}

func pct(_ share: Double) -> String {
    share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%"
}

struct Card<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    /// Stretch to the height the parent offers (used to make side-by-side columns end evenly).
    var fillHeight = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage {
        if let i = icons[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        icons[path] = i
        return i
    }
}

struct AppIcon: View {
    @EnvironmentObject var tracker: Tracker
    let name: String
    var size: CGFloat = 28
    var body: some View {
        if let p = tracker.appPaths[name] {
            Image(nsImage: IconCache.icon(p)).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "gearshape.fill")
                .font(.system(size: size * 0.5))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.25).fill(Color.white.opacity(0.08)))
        }
    }
}

struct BatteryRing: View {
    let info: BatteryInfo
    var body: some View {
        let c = Palette.level(info.percent, charging: info.charging || info.pluggedIn)
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 12)
            Circle()
                .trim(from: 0, to: info.percent / 100)
                .stroke(c, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: info.percent)
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    if info.charging { Image(systemName: "bolt.fill").font(.caption).foregroundStyle(c) }
                    Text("\(Int(info.percent.rounded()))")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                    Text("%").font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
        }
        .frame(width: 112, height: 112)
    }
}

func statusText(_ b: BatteryInfo) -> String {
    if !b.hasBattery { return "No battery detected" }
    if b.charging { return "Charging" }
    if b.pluggedIn { return "Plugged in" }
    if let m = b.minutesRemaining { return "On battery · \(m / 60)h \(m % 60)m left" }
    return "On battery"
}

enum DashTab: String, CaseIterable, Identifiable {
    case overview = "Overview", insights = "Insights", settings = "Settings"
    var id: String { rawValue }
}

enum DashSheet: Identifiable {
    case detail(RankedApp), other, all
    var id: String {
        switch self {
        case .detail(let a): "detail-\(a.name)"
        case .other: "other"
        case .all: "all"
        }
    }
}

@MainActor
func showDashboard(_ open: OpenWindowAction) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    open(id: "main")
}

struct DashboardView: View {
    @EnvironmentObject var tracker: Tracker
    @EnvironmentObject var settings: Settings   // re-render when the suggestion limits change
    @State private var tab: DashTab = .overview
    @State private var range: TimeRange = .hour
    @State private var onlyOnBattery = false
    @State private var appsOnly = false
    @State private var target: RankedApp?
    @State private var targetProcesses = 0
    @State private var message: String?
    @State private var sheet: DashSheet?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private func isApp(_ n: String) -> Bool { tracker.appPaths[n] != nil }

    private func perform(_ app: RankedApp, force: Bool) {
        switch Killer.quit(name: app.name, appPath: tracker.appPaths[app.name], force: force) {
        case .done(let n): message = "Sent \(force ? "force quit" : "quit") to \(app.name) (\(n) process\(n == 1 ? "" : "es")). It may take a moment to close."
        case .notRunning: message = "\(app.name) isn't running anymore."
        case .denied: message = "macOS won't let this app stop \(app.name) — it belongs to the system and needs administrator rights."
        }
    }

    private func requestQuit(_ app: RankedApp) {
        let set = {
            targetProcesses = Killer.pids(for: app.name, appPath: tracker.appPaths[app.name]).count
            target = app
        }
        if sheet != nil {
            sheet = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: set)
        } else { set() }
    }

    /// Opens an app's detail, replacing any sheet already showing (e.g. from the app list).
    private func openDetail(_ app: RankedApp) {
        if sheet != nil {
            sheet = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { sheet = .detail(app) }
        } else { sheet = .detail(app) }
    }

    /// Explains how many processes a quit reaches, when it's more than one.
    private func processCountNote(_ app: RankedApp) -> String {
        guard targetProcesses > 1 else { return "" }
        return isApp(app.name)
            ? "\nThis stops all \(targetProcesses) of its processes."
            : "\nThis stops all \(targetProcesses) running processes named “\(app.name)”."
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "battery-analysis-\(range.rawValue.replacingOccurrences(of: " ", with: "-")).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try tracker.csv(range: range).write(to: url, atomically: true, encoding: .utf8) }
        catch { message = "Couldn't save the file: \(error.localizedDescription)" }
    }

    var body: some View {
        let a = tracker.analyze(range: range, onlyOnBattery: onlyOnBattery, appsOnly: appsOnly)
        let note = target.flatMap { ProcessCatalog.note(for: $0.name, isApp: isApp($0.name)) }
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.12), Color(red: 0.04, green: 0.04, blue: 0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    controls
                    if tab != .settings { hero(a) }
                    if tab == .overview {
                        if a.ranked.isEmpty { emptyState } else { overview(a) }
                    } else {
                        if tab == .insights { InsightsView(range: range, appsOnly: appsOnly) } else { SettingsView() }
                    }
                    if tab == .insights {
                        Text("“Energy” is macOS’s Energy Impact score. It is a relative measure of power draw. Data stays on your computer and is kept for 30 days.")
                            .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 24)
            }
        }
        .sheet(item: $sheet) { sh in
            switch sh {
            case .detail(let app):
                DetailView(app: app, range: range, onlyOnBattery: onlyOnBattery, onQuit: { requestQuit(app) })
                    .environmentObject(tracker)
            case .other, .all:
                OtherAppsView(analysis: a, showAll: sh.id == "all",
                              onSelect: { openDetail($0) }, onQuit: { requestQuit($0) })
                    .environmentObject(tracker)
            }
        }
        .confirmationDialog(
            target.map { "Quit \($0.name)?" } ?? "",
            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
            titleVisibility: .visible
        ) {
            if let t = target {
                Button("Quit") { perform(t, force: false) }
                Button("Force Quit", role: .destructive) { perform(t, force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = target.map(processCountNote) ?? ""
            if let n = note {
                Text("\(n.text)\n\(n.importance.hint). macOS may restart it automatically.\(count)")
            } else {
                Text("Unsaved work in this app may be lost.\(count)")
            }
        }
        .alert("Heads up", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text("Battery Analysis").font(.title2.weight(.semibold))
                Spacer()
                if tab == .overview { searchField }
                Picker("", selection: $tab) {
                    ForEach(DashTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 270).labelsHidden()
                Button { exportCSV() } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless).help("Export this range as CSV")
            }
            if tab != .settings { HStack(spacing: 16) {
                Spacer()
                Toggle("Apps only", isOn: $appsOnly).toggleStyle(.switch).controlSize(.small)
                    .help("Hide system processes")
                Toggle("Only on battery", isOn: $onlyOnBattery).toggleStyle(.switch).controlSize(.small)
                Picker("", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 320).labelsHidden()
            } }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search apps & processes", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            // ⌘F focuses the field
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0, height: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: 230)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(searchFocused ? 0.3 : 0.08)))
    }

    /// Matches on the app/process name or its plain-English description.
    private func matches(_ app: RankedApp) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        if app.name.localizedCaseInsensitiveContains(q) { return true }
        return ProcessCatalog.note(for: app.name, isApp: isApp(app.name))?.text.localizedCaseInsensitiveContains(q) ?? false
    }

    private func hero(_ a: Analysis) -> some View {
        let b = tracker.battery
        let drainer = a.ranked.first { r in
            r.name != "BatteryAnalysis" && ProcessCatalog.note(for: r.name, isApp: isApp(r.name))?.importance != .critical
        }
        let suggesting = tracker.lowPowerSuggestion != nil
        return HStack(spacing: 28) {
            BatteryRing(info: b)
            VStack(alignment: .leading, spacing: 8) {
                Text(statusText(b)).font(.subheadline).foregroundStyle(.secondary)
                if let top = a.ranked.first {
                    HStack(spacing: 12) {
                        AppIcon(name: top.name, size: 40)
                        (Text(top.name).foregroundStyle(Palette.accents[0]).bold()
                         + Text(" is your biggest drain — \(pct(top.share)) of energy in the last \(range.rawValue).")).font(.title3)
                    }
                    if a.ranked.count >= 3 {
                        let t3 = a.ranked.prefix(3).map(\.share).reduce(0, +)
                        Text("The top 3 apps account for \(pct(t3)) of the total.").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Collecting data…").font(.title3)
                }
                if let tip = tracker.lowPowerSuggestion {
                    suggestionBanner(tip, drainer: drainer)
                } else if tracker.lowPower {
                    Label("Low Power Mode is on", systemImage: "leaf.fill")
                        .font(.caption).foregroundStyle(Importance.optional.color).padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(
            LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(suggesting ? Palette.warning.opacity(0.55) : Color.white.opacity(0.1)))
    }

    private func suggestionBanner(_ tip: String, drainer: RankedApp?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "leaf.fill").font(.title3).foregroundStyle(Palette.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Suggestion: turn on Low Power Mode").font(.callout.weight(.semibold))
                Text("\(tip) Low Power Mode cuts background activity to stretch your battery.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Button("Open Battery Settings") { LowPower.openBatterySettings() }
                if let d = drainer {
                    Button("Quit \(d.name)") { requestQuit(d) }
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.warning.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.warning.opacity(0.35)))
        .padding(.top, 4)
    }

    private var emptyState: some View {
        Card(title: "Nothing to show yet") {
            Text(onlyOnBattery && !tracker.samples.contains(where: { !$0.ac })
                 ? "No on-battery data yet. Unplug your Mac for a while, or turn off “Only on battery”."
                 : "The app samples every 30 seconds. Charts will appear in a minute or so. Keep it running (it lives in the menu bar when the window is closed) to build up history.")
                .foregroundStyle(.secondary)
        }
    }

    private func overview(_ a: Analysis) -> some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let rows = searching ? a.ranked.filter(matches) : Array(a.ranked.prefix(8))
        return HStack(alignment: .top, spacing: 18) {
            Card(title: searching ? "\(rows.count) result\(rows.count == 1 ? "" : "s")" : "Top energy users",
                 subtitle: searching ? "Matching “\(query)” in the last \(range.rawValue)" : "Share of total energy used · click an app for details",
                 fillHeight: true) {
                VStack(spacing: 14) {
                    ForEach(rows) { app in
                        AppRow(app: app, analysis: a, onSelect: { openDetail(app) }, onQuit: { requestQuit(app) })
                    }
                    if searching && rows.isEmpty {
                        Text("Nothing matches. Try part of a name, or a word like “backup” or “Siri”.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !searching && a.ranked.count > 5 {
                        Button { sheet = .all } label: {
                            Label("See all \(a.ranked.count) apps", systemImage: "list.bullet")
                        }
                        .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 380)
            VStack(spacing: 18) {
                Card(title: "Energy use over time", subtitle: "Taller = more power drawn", fillHeight: true) { timeline(a) }
                Card(title: "Battery level") { levelChart(a) }
            }
            .frame(maxHeight: .infinity)
        }
        // Size the row to its taller column, so the right column stretches to match the list.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func timeline(_ a: Analysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart(a.series) { p in
                AreaMark(x: .value("Time", p.date), y: .value("Energy", p.value))
                    .foregroundStyle(by: .value("App", p.app))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(domain: a.seriesNames, range: a.seriesNames.map { Palette.color(for: $0, in: a) })
            .chartLegend(.hidden)
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Color.white.opacity(0.06)); AxisValueLabel().foregroundStyle(Palette.axis) } }
            .frame(minHeight: 190, idealHeight: 190, maxHeight: .infinity)
            FlowLegend(names: a.seriesNames, analysis: a, onOther: { sheet = .other })
        }
    }

    private func levelChart(_ a: Analysis) -> some View {
        Chart {
            ForEach(Array(a.battery.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("Time", p.date), y: .value("%", p.percent))
                    .foregroundStyle(LinearGradient(colors: [Color.white.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.date), y: .value("%", p.percent))
                    .foregroundStyle(Color.white.opacity(0.85)).interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis { AxisMarks(values: [0, 50, 100]) { _ in AxisGridLine().foregroundStyle(Color.white.opacity(0.06)); AxisValueLabel().foregroundStyle(Palette.axis) } }
        .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Palette.axis) } }
        .frame(height: 110)
    }
}

/// One ranked app/process: icon, name, badge, description, share bar and quit button.
struct AppRow: View {
    @EnvironmentObject var tracker: Tracker
    let app: RankedApp
    let analysis: Analysis
    var onSelect: (() -> Void)? = nil
    let onQuit: () -> Void

    var body: some View {
        let isApp = tracker.appPaths[app.name] != nil
        let note = ProcessCatalog.note(for: app.name, isApp: isApp)
        let locked = note?.importance == .critical || app.name == "BatteryAnalysis"
        HStack(spacing: 12) {
            AppIcon(name: app.name)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(app.name).lineLimit(1).font(.callout)
                    if let n = note { ImportanceBadge(importance: n.importance) }
                    Spacer()
                    Text(pct(app.share)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button(action: onQuit) {
                        Image(systemName: locked ? "lock.fill" : "xmark.circle.fill")
                            .foregroundStyle(locked ? Color.white.opacity(0.18) : Color.white.opacity(0.4))
                    }
                    .buttonStyle(.plain).disabled(locked)
                    .help(locked ? "Critical to macOS — can't be quit from here" : "Quit \(app.name)")
                }
                if let n = note {
                    Text(n.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                GeometryReader { g in
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(Palette.color(for: app.name, in: analysis))
                        .frame(width: max(4, g.size.width * app.share / (analysis.ranked.first?.share ?? 1)))
                }
                .frame(height: 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
    }
}

struct FlowLegend: View {
    let names: [String]
    let analysis: Analysis
    var onOther: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 14) {
            ForEach(names, id: \.self) { n in
                let chip = HStack(spacing: 5) {
                    Circle().fill(Palette.color(for: n, in: analysis)).frame(width: 8, height: 8)
                    Text(n == "Other" && onOther != nil ? "Other ›" : n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if n == "Other", let onOther {
                    Button(action: onOther) { chip }.buttonStyle(.plain).help("See what's in Other")
                } else { chip }
            }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var tracker: Tracker
    @Environment(\.openWindow) private var openWindow
    @State private var contentHeight: CGFloat = 0
    var body: some View {
        let a = tracker.analyze(range: .hour, onlyOnBattery: false)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: batterySymbol(tracker.battery))
                Text("\(Int(tracker.battery.percent.rounded()))%").font(.headline)
                Spacer()
                Text(statusText(tracker.battery)).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Biggest drains · last hour").font(.caption).foregroundStyle(.secondary)
            if a.ranked.isEmpty { Text("Collecting data…").font(.callout) }
            ForEach(a.ranked.prefix(4)) { app in
                HStack(spacing: 8) {
                    AppIcon(name: app.name, size: 20)
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text(pct(app.share)).monospacedDigit().foregroundStyle(.secondary)
                }.font(.callout)
                .help(ProcessCatalog.note(for: app.name, isApp: tracker.appPaths[app.name] != nil)?.text ?? "")
            }
            Divider()
            HStack {
                Button("Open Dashboard") { showDashboard(openWindow) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14).frame(width: 330)
        .fixedSize(horizontal: false, vertical: true)          // report the real content height
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.popover.ignoresSafeArea())
        .background(SolidPanel(contentHeight: contentHeight))
    }
}


/// Makes the menu bar popover's window opaque (no translucent material or see-through border),
/// and resizes it to fit its content. The system panel grows when content grows but never
/// shrinks back, which left empty space after collapsing "Warning limits".
struct SolidPanel: NSViewRepresentable {
    var contentHeight: CGFloat = 0

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { Self.apply(v.window, height: contentHeight) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        let h = contentHeight
        DispatchQueue.main.async { Self.apply(v.window, height: h) }
    }

    private static func apply(_ w: NSWindow?, height: CGFloat) {
        guard let w else { return }
        w.isOpaque = true
        w.backgroundColor = NSColor(red: 0.09, green: 0.10, blue: 0.14, alpha: 1)
        // Remove the system vibrancy layers behind our content.
        func strip(_ v: NSView) {
            for sub in v.subviews {
                if let fx = sub as? NSVisualEffectView { fx.isHidden = true }
                strip(sub)
            }
        }
        if let root = w.contentView?.superview { strip(root) }

        // Fit the panel to the content, keeping its top edge pinned under the menu bar.
        // (Only the borderless menu bar panel; leave normal titled windows alone.)
        guard height > 0, !w.styleMask.contains(.titled) else { return }
        let target = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w.frame.width, height: height)).height
        guard abs(w.frame.height - target) > 0.5 else { return }
        var f = w.frame
        f.origin.y += f.height - target
        f.size.height = target
        w.setFrame(f, display: true)
    }
}
