import SwiftUI
import Charts

struct InsightsView: View {
    @EnvironmentObject var tracker: Tracker
    let range: TimeRange
    let appsOnly: Bool

    var body: some View {
        VStack(spacing: 18) {
            weeklyCard
            HStack(alignment: .top, spacing: 18) {
                healthCard.frame(maxWidth: 340)
                compareCard
            }
        }
    }

    // MARK: Weekly summary

    private var weeklyCard: some View {
        let w = tracker.weekly(appsOnly: appsOnly)
        return Card(title: "This week", subtitle: w.hasLast ? "Compared with the week before" : "Last 7 days · comparisons appear after two weeks of history") {
            if w.thisWeek.isEmpty {
                Text("Not enough data yet.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(w.thisWeek.prefix(3)) { app in
                        HStack(spacing: 12) {
                            AppIcon(name: app.name, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.callout.weight(.medium))
                                Text(sentence(app, w)).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(pct(app.share)).font(.title3.monospacedDigit().weight(.semibold))
                        }
                    }
                }
            }
        }
    }

    private func sentence(_ app: RankedApp, _ w: WeeklySummary) -> String {
        guard w.hasLast else { return "\(pct(app.share)) of your energy this week." }
        let prev = w.lastWeek[app.name] ?? 0
        let delta = app.share - prev
        if abs(delta) < 0.02 { return "About the same as last week (\(pct(prev)))." }
        return "\(delta > 0 ? "Up" : "Down") from \(pct(prev)) last week."
    }

    // MARK: Battery health

    private var healthCard: some View {
        Card(title: "Battery health") {
            if let h = tracker.health {
                VStack(spacing: 12) {
                    row("Condition", h.condition, color: h.condition == "Normal" ? Importance.optional.color : Importance.important.color)
                    if let m = h.maxCapacity { row("Maximum capacity", "\(m)%") }
                    if let c = h.cycles { row("Charge cycles", "\(c)") }
                    if let w = h.systemWatts { LiveWattsRow(fallback: w) }
                    if let a = h.adapterWatts, tracker.battery.pluggedIn { row("Charger", "\(a) W") }
                }
            } else {
                Text("No battery detected.").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ k: String, _ v: String, color: Color? = nil) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(color ?? .primary)
        }
        .font(.callout)
    }

    // MARK: Plugged in vs on battery

    private var compareCard: some View {
        let data = tracker.compareModes(range: range, appsOnly: appsOnly)
        return Card(title: "Plugged in vs. on battery", subtitle: "Share of energy for your top apps on battery, versus when charging") {
            if data.isEmpty {
                Text("Needs some time both plugged in and on battery in this range.").font(.callout).foregroundStyle(.secondary)
            } else {
                Chart(data) { d in
                    BarMark(x: .value("Share", d.share * 100), y: .value("App", d.app))
                        .foregroundStyle(by: .value("Mode", d.mode))
                        .position(by: .value("Mode", d.mode))
                        .cornerRadius(3)
                }
                .chartForegroundStyleScale(["On battery": Palette.accents[3], "Plugged in": Palette.accents[0]])
                .chartXAxis { AxisMarks { v in AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel { if let x = v.as(Double.self) { Text("\(Int(x))%") } }.foregroundStyle(Palette.axis) } }
                .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Palette.axis) } }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 260)
            }
        }
    }
}

/// "Using right now", kept in its own view so live readings redraw only this line.
private struct LiveWattsRow: View {
    @ObservedObject private var live = LiveWatts.shared
    let fallback: Double
    var body: some View {
        HStack {
            Text("Using right now").foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.1f W", live.watts ?? fallback)).font(.callout.monospacedDigit().weight(.medium))
        }
        .font(.callout)
    }
}

/// The dashboard's Settings tab.
struct SettingsView: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                Card(title: "General") {
                    VStack(spacing: 16) {
                        row("Launch at login", "Starts quietly in the menu bar, no window.", $settings.launchAtLogin)
                        row("Show wattage in menu bar", LiveWatts.shared.sensorAvailable
                            ? "Live power draw next to the bolt, from your Mac's power sensor."
                            : "Live power draw next to the bolt. This Mac has no fast power sensor, so it updates about once a minute.",
                            $settings.showWatts)
                        if LiveWatts.shared.sensorAvailable {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Update every").font(.callout)
                                    Text("Faster updates use a little more energy.").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Picker("", selection: $settings.wattsInterval) {
                                    ForEach(Settings.wattsIntervals, id: \.self) { Text("\($0) s").tag($0) }
                                }
                                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                            }
                            .disabled(!settings.showWatts)
                        }
                    }
                }
                Card(title: "Notifications") {
                    VStack(spacing: 16) {
                        row("Drain alerts", "Notify when one app uses 40%+ of your energy for 10 minutes.", $settings.drainAlerts)
                        row("Low-battery alert", "Notify at the level below and name your biggest drain.", $settings.lowBatteryAlerts)
                        limit("Low-battery alert at", $settings.lowBatteryPercent, 5...40, step: 5, unit: "%")
                            .disabled(!settings.lowBatteryAlerts)
                    }
                }
            }
            Card(title: "Low Power Mode suggestion",
                 subtitle: "When to suggest turning on Low Power Mode. The app never changes the setting itself.") {
                VStack(alignment: .leading, spacing: 16) {
                    row("Suggest Low Power Mode", "Shows a suggestion on the dashboard and turns the menu bar bolt yellow.", $settings.lpmSuggest)
                    Group {
                        limit("Suggest when battery is at or below", $settings.lpmPercent, 10...60, step: 5, unit: "%")
                        limit("…and your Mac is using at least", $settings.lpmWatts, 0...30, step: 1, unit: " W", zeroLabel: "any amount")
                        limit("Always suggest at or below", $settings.lpmCritical, 5...30, step: 5, unit: "%")
                    }
                    .disabled(!settings.lpmSuggest)
                    Button("Reset all limits to defaults") { settings.resetLimits() }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }

    private func limit(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, step: Int, unit: String, zeroLabel: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(value.wrappedValue == 0 && zeroLabel != nil ? zeroLabel! : "\(value.wrappedValue)\(unit)")
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
                .controlSize(.small)
        }
    }

    private func row(_ title: String, _ detail: String, _ on: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}
