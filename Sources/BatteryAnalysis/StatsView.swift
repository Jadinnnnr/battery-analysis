import SwiftUI

/// The dashboard's Stats tab: running energy totals, just for fun.
struct StatsView: View {
    @EnvironmentObject var tracker: Tracker
    @EnvironmentObject var settings: Settings
    @ObservedObject private var stats = EnergyStats.shared
    @State private var period: StatsPeriod = .all
    @State private var showAllApps = false
    @State private var confirmReset = false

    private var currency: String { Locale.current.currency?.identifier ?? "USD" }

    var body: some View {
        let t = stats.ledger.totals(for: period, now: Date().timeIntervalSince1970)
        VStack(spacing: 18) {
            HStack {
                Text("Since \(Date(timeIntervalSince1970: stats.ledger.since).formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $period) {
                    ForEach(StatsPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 340).labelsHidden()
            }
            if stats.ledger.days.isEmpty {
                Card(title: "Nothing counted yet") {
                    Text("Totals start now and update every 10 seconds while your Mac is awake. Check back in a minute.")
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 14) {
                    tile("Energy used", energyText(t.mac), sub: "by your Mac, devices included")
                    tile("Charged in", energyText(t.inflow), sub: "from chargers")
                    tile("Given to devices", energyText(t.outflow), sub: "through its ports")
                    tile("Time counted", durationText(t.seconds), sub: "while awake")
                }
                funCard(t)
                appsCard(t)
                HStack(alignment: .top, spacing: 18) {
                    inflowCard(t)
                    devicesCard(t)
                }
                .fixedSize(horizontal: false, vertical: true)
                recordsCard
            }
            VStack(spacing: 6) {
                Text("Counted only while your Mac is awake and this app is running. The Mac, chargers and devices are measured by its power sensors; the split between apps is an estimate from each app's share of Energy Impact. Kept on this Mac.")
                    .multilineTextAlignment(.center)
                Button("Reset stats…") { confirmReset = true }.buttonStyle(.borderless)
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .confirmationDialog("Reset all stats?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { stats.reset() }
        } message: {
            Text("This clears every total and record, and starts counting again from now.")
        }
    }

    // MARK: Cards

    private func funCard(_ t: EnergyLedger.Totals) -> some View {
        Card(title: "For fun", subtitle: "\(period == .all ? "All time" : period.rawValue), roughly") {
            VStack(alignment: .leading, spacing: 10) {
                fun("iphone", "Your Mac used as much as **\(approx(t.mac / EnergyStats.iPhoneChargeWh)) iPhone charges**.")
                fun("lightbulb.fill", "That would keep a 10 W LED bulb on for **\(durationText(t.mac / EnergyStats.bulbWatts * 3600))**.")
                HStack(spacing: 10) {
                    Image(systemName: "dollarsign.circle.fill").frame(width: 22).foregroundStyle(Palette.accents[3])
                    Text("Charging it cost about **\((t.inflow / 1000 * settings.kwhPrice).formatted(.currency(code: currency)))** at")
                    TextField("", value: $settings.kwhPrice, format: .currency(code: currency))
                        .textFieldStyle(.roundedBorder).frame(width: 64).multilineTextAlignment(.trailing)
                    Stepper("", value: $settings.kwhPrice, in: 0...2, step: 0.01).labelsHidden()
                    Text("per kWh.")
                }
                if let cap = tracker.health?.capacityWh, cap > 0 {
                    fun("battery.100percent.bolt", "It put **\(approx(t.battery / cap)) full charges** into the battery (\(energyText(cap)) each).")
                }
            }
            .font(.callout)
        }
    }

    private func appsCard(_ t: EnergyLedger.Totals) -> some View {
        let ranked = t.apps.sorted { $0.value > $1.value }
        let rows = showAllApps ? ranked : Array(ranked.prefix(10))
        let total = t.appsTotal
        let top = ranked.first?.value ?? 1
        return Card(title: "Energy by app", subtitle: "Estimated: the Mac's measured energy, split by each app's share of Energy Impact") {
            if ranked.isEmpty {
                Text("No apps counted in this period yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(rows, id: \.key) { name, wh in
                        HStack(spacing: 12) {
                            AppIcon(name: name, size: 24)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(name).lineLimit(1)
                                    Spacer()
                                    Text(energyText(wh)).monospacedDigit()
                                    Text(pct(total > 0 ? wh / total : 0)).monospacedDigit().foregroundStyle(.secondary)
                                        .frame(width: 40, alignment: .trailing)
                                }
                                .font(.callout)
                                GeometryReader { g in
                                    Capsule().fill(Color.white.opacity(0.07))
                                    Capsule().fill(Palette.accents[0]).frame(width: max(4, g.size.width * wh / top))
                                }
                                .frame(height: 5)
                            }
                        }
                    }
                    if ranked.count > 10 {
                        Button(showAllApps ? "Show top 10" : "Show all \(ranked.count)") { showAllApps.toggle() }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }

    private func inflowCard(_ t: EnergyLedger.Totals) -> some View {
        Card(title: "Energy in", subtitle: "From chargers", fillHeight: true) {
            if t.inflow <= 0 {
                Text("Nothing charged in this period.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    row("powerplug.fill", "Total", energyText(t.inflow), bold: true)
                    ForEach(t.chargers.sorted { $0.value > $1.value }, id: \.key) { name, wh in
                        row("powerplug", name, energyText(wh))
                    }
                    row("battery.100percent.bolt", "Into the battery", energyText(t.battery))
                    row("laptopcomputer", "Straight to the Mac", energyText(max(0, t.inflow - t.battery)))
                }
            }
        }
    }

    private func devicesCard(_ t: EnergyLedger.Totals) -> some View {
        Card(title: "Devices out", subtitle: "Power your Mac gave to connected devices", fillHeight: true) {
            if t.devices.isEmpty {
                Text("No devices drew power in this period.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    row("cable.connector", "Total", energyText(t.outflow), bold: true)
                    ForEach(t.devices.sorted { $0.value > $1.value }, id: \.key) { name, wh in
                        row(stats.ledger.deviceSymbols[name] ?? "cable.connector", name, energyText(wh))
                    }
                }
            }
        }
    }

    private var recordsCard: some View {
        let r = stats.ledger.records
        let all = stats.ledger.totals(for: .all, now: Date().timeIntervalSince1970)
        return Card(title: "Records", subtitle: "All time") {
            VStack(spacing: 10) {
                if let b = r.biggestDay { row("flame.fill", "Biggest day", "\(energyText(b.wh)) · \(dayText(b.day))") }
                if let p = r.peakCharging { row("bolt.fill", "Fastest charging", "\(wattsText(p.watts)) · \(dayText(p.day))") }
                if let h = r.hungriestApp { row("crown.fill", "Hungriest app in a day", "\(h.app) · \(energyText(h.wh)) · \(dayText(h.day))") }
                row("clock.fill", "Time counted", durationText(all.seconds))
            }
        }
    }

    // MARK: Pieces

    private func tile(_ title: String, _ value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.055)))
    }

    private func fun(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(Palette.accents[3])
            Text(text)
        }
    }

    private func row(_ symbol: String, _ name: String, _ value: String, bold: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(name).lineLimit(1)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(bold ? .primary : .secondary).lineLimit(1)
        }
        .font(bold ? .callout.weight(.semibold) : .callout)
    }

    private func dayText(_ key: String) -> String {
        EnergyLedger.date(fromKey: key)?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? key
    }
}

/// "0.4", "3.2", "27", "1,204": a decimal only while it matters.
func approx(_ x: Double) -> String {
    x < 10 ? String(format: "%.1f", x) : Int(x.rounded()).formatted()
}

/// "45 s", "12 min", "3 h 5 min", "2 d 4 h".
func durationText(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s) s" }
    let m = s / 60
    if m < 60 { return "\(m) min" }
    let h = m / 60
    if h < 48 { return m % 60 == 0 ? "\(h) h" : "\(h) h \(m % 60) min" }
    return h % 24 == 0 ? "\(h / 24) d" : "\(h / 24) d \(h % 24) h"
}
