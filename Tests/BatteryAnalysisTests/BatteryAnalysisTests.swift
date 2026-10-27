// Swift Testing rather than XCTest: it ships with the Command Line Tools as well as Xcode, so
// `swift test` works without installing Xcode.
import Foundation
import Testing
@testable import BatteryAnalysis

private func isClose(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

struct ParsingTests {
    @Test func parseRow() {
        #expect(TopStream.parseRow("1271   3.4")?.0 == 1271)
        #expect(TopStream.parseRow("1271   3.4")?.1 == 3.4)
        // The x86_64 build of top marks PIDs with a trailing "*".
        #expect(TopStream.parseRow("1271*  12.0")?.0 == 1271)
        #expect(TopStream.parseRow("PID    POWER") == nil)
        #expect(TopStream.parseRow("") == nil)
    }

    @Test func appIdentityFoldsHelpersIntoParentApp() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let id = Sampler.appIdentity(helper)
        #expect(id.name == "Google Chrome")
        #expect(id.appPath == "/Applications/Google Chrome.app")
    }

    @Test func appIdentityForPlainBinary() {
        let id = Sampler.appIdentity("/usr/libexec/mds_stores")
        #expect(id.name == "mds_stores")
        #expect(id.appPath == nil)
    }
}

struct ProcessCatalogTests {
    // System processes shipped as .app bundles in /System/Library/CoreServices must stay locked.
    @Test(arguments: ["loginwindow", "Finder", "Dock", "SystemUIServer"])
    func systemAppBundlesKeepTheirNotes(name: String) {
        #expect(ProcessCatalog.note(for: name, isApp: true)?.importance == .critical)
    }

    @Test func controlCenterIsImportant() {
        #expect(ProcessCatalog.note(for: "ControlCenter", isApp: true)?.importance == .important)
    }

    @Test func regularAppsHaveNoNote() {
        #expect(ProcessCatalog.note(for: "Google Chrome", isApp: true) == nil)
    }

    @Test func unknownProcessesGetGenericNotes() {
        #expect(ProcessCatalog.note(for: "somethingd", isApp: false)?.importance == .important)
        #expect(ProcessCatalog.note(for: "com.apple.foo", isApp: false)?.importance == .important)
    }
}

struct KillerTests {
    @Test func appsMatchOnBundlePath() {
        let exe = "/Applications/Foo.app/Contents/MacOS/Foo"
        #expect(Killer.matches(path: exe, name: "Foo", appPath: "/Applications/Foo.app"))
        // Another copy of the same app is a different entry.
        #expect(!Killer.matches(path: "/Users/me/Foo.app/Contents/MacOS/Foo", name: "Foo", appPath: "/Applications/Foo.app"))
    }

    @Test func processesMatchOnNameButNotInsideApps() {
        #expect(Killer.matches(path: "/opt/homebrew/bin/node", name: "node", appPath: nil))
        #expect(!Killer.matches(path: "/Applications/node.app/Contents/MacOS/node", name: "node", appPath: nil))
    }
}

@MainActor
struct AlertTests {
    private func samples(_ apps: [String: Double], count: Int = 10) -> [Sample] {
        let now = Date().timeIntervalSince1970
        return (0..<count).map { Sample(t: now - Double(count - $0) * 30, b: 50, ac: false, a: apps) }
    }

    @Test func topDrainerSkipsCriticalProcessesAndItself() {
        let s = samples(["kernel_task": 90, "BatteryAnalysis": 80, "loginwindow": 70, "Slack": 30])
        let d = Alerts.topDrainer(samples: s, appPaths: ["loginwindow": "/System/Library/CoreServices/loginwindow.app",
                                                         "Slack": "/Applications/Slack.app"])
        #expect(d?.name == "Slack")
    }

    @Test func topDrainerNeedsEnoughSamples() {
        #expect(Alerts.topDrainer(samples: samples(["Slack": 30], count: 3), appPaths: [:]) == nil)
    }
}

struct AnalysisTests {
    private let t0 = 1_700_000_000.0

    private func run(_ times: [Double], now: Double) -> Analysis {
        let s = times.map { Sample(t: t0 + $0, b: 50, ac: false, a: ["A": 30, "B": 10]) }
        return Tracker.analysis(of: s, appPaths: [:], appsOnly: false, now: t0 + now)
    }

    @Test func shares() {
        let a = run([0, 30, 60], now: 90)
        #expect(a.ranked.map(\.name) == ["A", "B"])
        #expect(isClose(a.ranked[0].share, 0.75))
    }

    @Test func sleepGapDrawsAsZero() {
        // An hour of samples, two hours asleep, then another hour.
        let awake1 = stride(from: 0.0, to: 3600, by: 30).map { $0 }
        let awake2 = stride(from: 3 * 3600.0, to: 4 * 3600, by: 30).map { $0 }
        let a = run(awake1 + awake2, now: 4 * 3600)
        let gap = a.series.filter { $0.date.timeIntervalSince1970 > t0 + 3700 && $0.date.timeIntervalSince1970 < t0 + 3 * 3600 - 100 }
        #expect(!gap.isEmpty)
        #expect(gap.allSatisfy { $0.value == 0 })
    }

    @Test func shortRangesDontDipToZero() {
        // Buckets narrower than two samples can come up empty from rounding alone.
        let a = run(stride(from: 0.0, to: 300, by: 30).map { $0 }, now: 300)
        #expect(a.series.allSatisfy { $0.value > 0 })
    }
}

struct ConnectedDeviceTests {
    @Test func deviceKinds() {
        #expect(DeviceKind.guess(name: "iPhone", interfaceClasses: [6, 255]) == .iPhone)
        #expect(DeviceKind.guess(name: "iPad Pro", interfaceClasses: []) == .iPad)
        #expect(DeviceKind.guess(name: "Pixel 9", interfaceClasses: [6]) == .phone)
        #expect(DeviceKind.guess(name: "T7 Shield", interfaceClasses: [8]) == .storage)
        // Webcams also have audio interfaces; video wins.
        #expect(DeviceKind.guess(name: "Brio 500", interfaceClasses: [1, 14]) == .camera)
        #expect(DeviceKind.guess(name: "Magic Keyboard", interfaceClasses: [3]) == .input)
        #expect(DeviceKind.guess(name: "Gadget", interfaceClasses: [255]) == .other)
    }

    private func port(_ n: Int) -> PortScanner.Port {
        PortScanner.Port(id: "Port-USB-C@\(n)", number: n, controller: n - 1, active: false, partnerName: nil)
    }

    @Test func sensorsDefaultToPortOrder() {
        // M5 MacBook Pro: USB-C@1, @2, @4 take D1-D3 (D4 is MagSafe).
        let map = ConnectedDevices.sensorMap(ports: [port(4), port(1), port(2)], sensors: [4, 2, 1, 3], learned: [:])
        #expect(map == ["Port-USB-C@1": 1, "Port-USB-C@2": 2, "Port-USB-C@4": 3])
    }

    @Test func learnedPairOverridesGuess() {
        let map = ConnectedDevices.sensorMap(ports: [port(1), port(2)], sensors: [1, 2], learned: ["Port-USB-C@1": 2])
        #expect(map["Port-USB-C@1"] == 2)
        #expect(map["Port-USB-C@2"] == nil)   // its guessed sensor was taken
    }

    @Test func learningNeedsOneActivePortAndOneDrawingSensor() {
        let phone: ConnectedDevices.Reading = (3.0, 5.2)
        let idle: ConnectedDevices.Reading = (0, 0)
        let charger: ConnectedDevices.Reading = (3.0, 20.0)   // power coming in, not going out
        #expect(ConnectedDevices.learn(active: ["A"], readings: [1: idle, 3: phone])?.sensor == 3)
        #expect(ConnectedDevices.learn(active: ["A"], readings: [3: phone, 4: charger])?.sensor == 3)
        #expect(ConnectedDevices.learn(active: ["A", "B"], readings: [3: phone]) == nil)
        #expect(ConnectedDevices.learn(active: ["A"], readings: [1: phone, 3: phone]) == nil)
    }
}

struct PortBadgeTests {
    @Test func circledDigits() {
        #expect(portBadge(1) == "①")
        #expect(portBadge(4) == "④")
        #expect(portBadge(20) == "⑳")
        #expect(portBadge(21) == "#21")
        #expect(portBadge(0) == "#0")
    }
}

struct InflowTests {
    @Test func chargerPortLabels() {
        #expect(Charger(port: "Port-USB-C@4", ratedWatts: 25, watts: 22).portLabel == "USB-C ④")
        #expect(Charger(port: "Port-MagSafe 3@1", ratedWatts: 96, watts: 60).portLabel == "MagSafe")
        #expect(Charger(port: nil, ratedWatts: nil, watts: 5).portLabel == "")
    }

    @Test func batteryRate() {
        #expect(batteryRateText(12.9) == "+13 W")
        #expect(batteryRateText(-3.2) == "−3.2 W")
        // Optimized Battery Charging holds the battery: tiny currents aren't charging.
        #expect(batteryRateText(0.1) == "Not charging")
        #expect(batteryRateText(nil) == "—")
    }
}

struct EnergyLedgerTests {
    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let noon = 1_790_000_000.0 - 1_790_000_000.0.truncatingRemainder(dividingBy: 86400) + 43200   // 12:00 UTC

    @Test func gapsAreNotCounted() {
        #expect(EnergyLedger.slice(dt: 10) == 10)
        #expect(EnergyLedger.slice(dt: 61) == nil)    // slept
        #expect(EnergyLedger.slice(dt: -5) == nil)    // clock went back
        var l = EnergyLedger(since: noon)
        l.add(at: noon, dt: 3600, mac: 10, inflow: nil, battery: nil, devices: [:], charger: nil, calendar: utc)
        #expect(l.days.isEmpty)
    }

    @Test func addIntegratesWattsIntoWattHours() throws {
        var l = EnergyLedger(since: noon)
        // 360 slices of 10 s = one hour at 20 W in, 12 W used, 15 W to an iPhone, 6 W into the battery.
        for i in 0..<360 {
            l.add(at: noon + Double(i) * 10, dt: 10, mac: 27, inflow: 20, battery: 6,
                  devices: ["iPhone": 15], charger: "USB-C ④ · 25 W", calendar: utc)
        }
        let d = try #require(l.days.values.first)
        #expect(isClose(d.mac, 27))
        #expect(isClose(d.appsPool, 12))     // the iPhone's share isn't any app's
        #expect(isClose(try #require(d.devices["iPhone"]), 15))
        #expect(isClose(d.inflow, 20))
        #expect(isClose(try #require(d.chargers["USB-C ④ · 25 W"]), 20))
        #expect(isClose(d.battery, 6))
        #expect(d.seconds == 3600)
        #expect(d.peakIn == 20)
    }

    @Test func dischargingIsNotChargingTheBattery() throws {
        var l = EnergyLedger(since: noon)
        l.add(at: noon, dt: 10, mac: 8, inflow: nil, battery: -8, devices: [:], charger: nil, calendar: utc)
        #expect(try #require(l.days.values.first).battery == 0)
    }

    @Test func appsSplitTheirPoolByEnergyImpact() throws {
        var l = EnergyLedger(since: noon)
        l.add(at: noon, dt: 36, mac: 100, inflow: nil, battery: nil, devices: [:], charger: nil, calendar: utc)   // 1 Wh
        l.attributeApps(impacts: [:])   // nothing to split by: the pool waits
        #expect(isClose(try #require(l.days.values.first).appsPool, 1))
        l.attributeApps(impacts: ["Safari": 30, "Xcode": 10, "idle": 0])
        let d = try #require(l.days.values.first)
        #expect(isClose(try #require(d.apps["Safari"]), 0.75))
        #expect(isClose(try #require(d.apps["Xcode"]), 0.25))
        #expect(d.apps["idle"] == nil)
        #expect(d.appsPool == 0)
    }

    @Test func periodsAndRecords() {
        var l = EnergyLedger(since: noon - 40 * 86400)
        for daysAgo in [0, 1, 6, 7, 29, 30] {
            let t = noon - Double(daysAgo) * 86400
            l.add(at: t, dt: 36, mac: 100 + Double(daysAgo), inflow: Double(daysAgo), battery: nil,
                  devices: [:], charger: nil, calendar: utc)
        }
        func mac(_ p: StatsPeriod) -> Double { l.totals(for: p, now: noon, calendar: utc).mac }
        #expect(isClose(mac(.today), 1.0))
        #expect(isClose(mac(.week), (300 + 1 + 6) / 100))            // today, 1 and 6 days ago
        #expect(isClose(mac(.month), (500 + 1 + 6 + 7 + 29) / 100))  // up to 29 days ago
        #expect(isClose(mac(.all), (600 + 1 + 6 + 7 + 29 + 30) / 100))

        let r = l.records
        #expect(isClose(r.biggestDay?.wh ?? 0, 1.3))
        #expect(r.peakCharging?.watts == 30)
        #expect(r.biggestDay?.day == EnergyLedger.dayKey(noon - 30 * 86400, calendar: utc))
    }

    @Test func codableRoundTrip() throws {
        var l = EnergyLedger(since: noon)
        l.add(at: noon, dt: 10, mac: 9, inflow: 20, battery: 5, devices: ["iPhone": 4], charger: "MagSafe · 96 W", calendar: utc)
        l.attributeApps(impacts: ["Safari": 1])
        l.deviceSymbols["iPhone"] = "iphone"
        let back = try JSONDecoder().decode(EnergyLedger.self, from: JSONEncoder().encode(l))
        #expect(back == l)
    }

    @Test func formatting() {
        #expect(energyText(0.42) == "0.4 Wh")
        #expect(energyText(742.4) == "742 Wh")
        #expect(energyText(1240) == "1.24 kWh")
        #expect(durationText(45) == "45 s")
        #expect(durationText(3 * 3600 + 300) == "3 h 5 min")
        #expect(durationText(52 * 3600) == "2 d 4 h")
        #expect(approx(3.24) == "3.2")
    }
}
