import SwiftUI
import Charts

struct DetailView: View {
    @EnvironmentObject var tracker: Tracker
    @Environment(\.dismiss) private var dismiss
    let app: RankedApp
    let range: TimeRange
    let onlyOnBattery: Bool
    let onQuit: () -> Void

    var body: some View {
        let h = tracker.history(for: app.name, range: range, onlyOnBattery: onlyOnBattery)
        let isApp = tracker.appPaths[app.name] != nil
        let note = ProcessCatalog.note(for: app.name, isApp: isApp)
        let locked = note?.importance == .critical || app.name == "BatteryAnalysis"
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    AppIcon(name: app.name, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(app.name).font(.title2.weight(.semibold))
                            if let n = note { ImportanceBadge(importance: n.importance) }
                        }
                        if let n = note { Text(n.text).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }

                HStack(spacing: 14) {
                    stat("Share of energy", pct(app.share), sub: "last \(range.rawValue)")
                    stat("Average energy", String(format: "%.1f", h.average), sub: "Energy Impact score")
                    trendStat(h.trend)
                }

                Card(title: "Energy over time", subtitle: "Last \(range.rawValue)") {
                    Chart(Array(h.points.enumerated()), id: \.offset) { _, p in
                        AreaMark(x: .value("Time", p.date), y: .value("Energy", p.value))
                            .foregroundStyle(LinearGradient(colors: [Palette.accents[0].opacity(0.5), .clear], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", p.date), y: .value("Energy", p.value))
                            .foregroundStyle(Palette.accents[0]).interpolationMethod(.monotone)
                    }
                    .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Color.white.opacity(0.06)); AxisValueLabel().foregroundStyle(Palette.axis) } }
                    .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Palette.axis) } }
                    .frame(height: 170)
                }

                Card(title: "Share of energy by day", subtitle: "How much of your total energy this took each day") {
                    if h.daily.count < 2 {
                        Text("Needs at least two days of history.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Chart(Array(h.daily.enumerated()), id: \.offset) { _, d in
                            BarMark(x: .value("Day", d.day, unit: .day), y: .value("Share", d.share * 100))
                                .foregroundStyle(Palette.accents[1]).cornerRadius(4)
                        }
                        .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                            AxisValueLabel { if let x = v.as(Double.self) { Text("\(Int(x))%") } }.foregroundStyle(Palette.axis) } }
                        .frame(height: 150)
                    }
                }

                Button(role: .destructive, action: onQuit) { Label("Quit \(app.name)…", systemImage: "xmark.circle") }
                    .disabled(locked)
                    .help(locked ? "Critical to macOS — can't be quit from here" : "")
            }
            .padding(24)
        }
        .frame(width: 640, height: 720)
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
    }

    private func stat(_ title: String, _ value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(sub).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.055)))
    }

    @ViewBuilder
    private func trendStat(_ t: Double?) -> some View {
        if let t {
            let up = t > 0
            VStack(alignment: .leading, spacing: 4) {
                Text("Trend").font(.caption).foregroundStyle(.secondary)
                Text("\(up ? "↑" : "↓") \(Int(abs(t) * 100))%")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(up ? Importance.critical.color : Importance.optional.color)
                Text("newer half vs older half").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.055)))
        } else {
            stat("Trend", "—", sub: "not enough data yet")
        }
    }
}

struct OtherAppsView: View {
    @EnvironmentObject var tracker: Tracker
    @Environment(\.dismiss) private var dismiss
    let analysis: Analysis

    var body: some View {
        let rest = Array(analysis.ranked.dropFirst(5))
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's in “Other”").font(.title3.weight(.semibold))
                    Text("Everything beyond the top 5, \(rest.count) in total").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(rest) { app in
                        AppRow(app: app, analysis: analysis, onQuit: {})
                            .environmentObject(tracker)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: 560)
        .background(Color(red: 0.07, green: 0.08, blue: 0.12))
    }
}
