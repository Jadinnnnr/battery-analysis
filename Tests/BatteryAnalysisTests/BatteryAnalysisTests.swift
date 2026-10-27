import XCTest
@testable import BatteryAnalysis

final class ParsingTests: XCTestCase {
    func testParseRow() {
        XCTAssertEqual(TopStream.parseRow("1271   3.4")?.0, 1271)
        XCTAssertEqual(TopStream.parseRow("1271   3.4")?.1, 3.4)
        // The x86_64 build of top marks PIDs with a trailing "*".
        XCTAssertEqual(TopStream.parseRow("1271*  12.0")?.0, 1271)
        XCTAssertNil(TopStream.parseRow("PID    POWER"))
        XCTAssertNil(TopStream.parseRow(""))
    }

    func testAppIdentityFoldsHelpersIntoParentApp() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let id = Sampler.appIdentity(helper)
        XCTAssertEqual(id.name, "Google Chrome")
        XCTAssertEqual(id.appPath, "/Applications/Google Chrome.app")
    }

    func testAppIdentityForPlainBinary() {
        let id = Sampler.appIdentity("/usr/libexec/mds_stores")
        XCTAssertEqual(id.name, "mds_stores")
        XCTAssertNil(id.appPath)
    }
}

final class ProcessCatalogTests: XCTestCase {
    // System processes shipped as .app bundles in /System/Library/CoreServices must stay locked.
    func testSystemAppBundlesKeepTheirNotes() {
        for name in ["loginwindow", "Finder", "Dock", "SystemUIServer"] {
            XCTAssertEqual(ProcessCatalog.note(for: name, isApp: true)?.importance, .critical, name)
        }
        XCTAssertEqual(ProcessCatalog.note(for: "ControlCenter", isApp: true)?.importance, .important)
    }

    func testRegularAppsHaveNoNote() {
        XCTAssertNil(ProcessCatalog.note(for: "Google Chrome", isApp: true))
    }

    func testUnknownProcessesGetGenericNotes() {
        XCTAssertEqual(ProcessCatalog.note(for: "somethingd", isApp: false)?.importance, .important)
        XCTAssertEqual(ProcessCatalog.note(for: "com.apple.foo", isApp: false)?.importance, .important)
    }
}

final class KillerTests: XCTestCase {
    func testAppsMatchOnBundlePath() {
        let exe = "/Applications/Foo.app/Contents/MacOS/Foo"
        XCTAssertTrue(Killer.matches(path: exe, name: "Foo", appPath: "/Applications/Foo.app"))
        // Another copy of the same app is a different entry.
        XCTAssertFalse(Killer.matches(path: "/Users/me/Foo.app/Contents/MacOS/Foo", name: "Foo", appPath: "/Applications/Foo.app"))
    }

    func testProcessesMatchOnNameButNotInsideApps() {
        XCTAssertTrue(Killer.matches(path: "/opt/homebrew/bin/node", name: "node", appPath: nil))
        XCTAssertFalse(Killer.matches(path: "/Applications/node.app/Contents/MacOS/node", name: "node", appPath: nil))
    }
}

@MainActor
final class AlertTests: XCTestCase {
    private func samples(_ apps: [String: Double], count: Int = 10) -> [Sample] {
        let now = Date().timeIntervalSince1970
        return (0..<count).map { Sample(t: now - Double(count - $0) * 30, b: 50, ac: false, a: apps) }
    }

    func testTopDrainerSkipsCriticalProcessesAndItself() {
        let s = samples(["kernel_task": 90, "BatteryAnalysis": 80, "loginwindow": 70, "Slack": 30])
        let d = Alerts.topDrainer(samples: s, appPaths: ["loginwindow": "/System/Library/CoreServices/loginwindow.app",
                                                         "Slack": "/Applications/Slack.app"])
        XCTAssertEqual(d?.name, "Slack")
    }

    func testTopDrainerNeedsEnoughSamples() {
        XCTAssertNil(Alerts.topDrainer(samples: samples(["Slack": 30], count: 3), appPaths: [:]))
    }
}

final class AnalysisTests: XCTestCase {
    private let t0 = 1_700_000_000.0

    private func run(_ times: [Double], now: Double) -> Analysis {
        let s = times.map { Sample(t: t0 + $0, b: 50, ac: false, a: ["A": 30, "B": 10]) }
        return Tracker.analysis(of: s, appPaths: [:], appsOnly: false, now: t0 + now)
    }

    func testShares() {
        let a = run([0, 30, 60], now: 90)
        XCTAssertEqual(a.ranked.map(\.name), ["A", "B"])
        XCTAssertEqual(a.ranked[0].share, 0.75, accuracy: 1e-9)
    }

    func testSleepGapDrawsAsZero() {
        // An hour of samples, two hours asleep, then another hour.
        let awake1 = stride(from: 0.0, to: 3600, by: 30).map { $0 }
        let awake2 = stride(from: 3 * 3600.0, to: 4 * 3600, by: 30).map { $0 }
        let a = run(awake1 + awake2, now: 4 * 3600)
        let gap = a.series.filter { $0.date.timeIntervalSince1970 > t0 + 3700 && $0.date.timeIntervalSince1970 < t0 + 3 * 3600 - 100 }
        XCTAssertFalse(gap.isEmpty)
        XCTAssertTrue(gap.allSatisfy { $0.value == 0 })
    }

    func testShortRangesDontDipToZero() {
        // Buckets narrower than two samples can come up empty from rounding alone.
        let a = run(stride(from: 0.0, to: 300, by: 30).map { $0 }, now: 300)
        XCTAssertTrue(a.series.allSatisfy { $0.value > 0 })
    }
}

final class ConnectedDeviceTests: XCTestCase {
    func testDeviceKinds() {
        XCTAssertEqual(DeviceKind.guess(name: "iPhone", interfaceClasses: [6, 255]), .iPhone)
        XCTAssertEqual(DeviceKind.guess(name: "iPad Pro", interfaceClasses: []), .iPad)
        XCTAssertEqual(DeviceKind.guess(name: "Pixel 9", interfaceClasses: [6]), .phone)
        XCTAssertEqual(DeviceKind.guess(name: "T7 Shield", interfaceClasses: [8]), .storage)
        // Webcams also have audio interfaces; video wins.
        XCTAssertEqual(DeviceKind.guess(name: "Brio 500", interfaceClasses: [1, 14]), .camera)
        XCTAssertEqual(DeviceKind.guess(name: "Magic Keyboard", interfaceClasses: [3]), .input)
        XCTAssertEqual(DeviceKind.guess(name: "Gadget", interfaceClasses: [255]), .other)
    }

    private func port(_ n: Int) -> PortScanner.Port {
        PortScanner.Port(id: "Port-USB-C@\(n)", number: n, controller: n - 1, active: false, partnerName: nil)
    }

    func testSensorsDefaultToPortOrder() {
        // M5 MacBook Pro: USB-C@1, @2, @4 take D1-D3 (D4 is MagSafe).
        let map = ConnectedDevices.sensorMap(ports: [port(4), port(1), port(2)], sensors: [4, 2, 1, 3], learned: [:])
        XCTAssertEqual(map, ["Port-USB-C@1": 1, "Port-USB-C@2": 2, "Port-USB-C@4": 3])
    }

    func testLearnedPairOverridesGuess() {
        let map = ConnectedDevices.sensorMap(ports: [port(1), port(2)], sensors: [1, 2], learned: ["Port-USB-C@1": 2])
        XCTAssertEqual(map["Port-USB-C@1"], 2)
        XCTAssertNil(map["Port-USB-C@2"])   // its guessed sensor was taken
    }

    func testLearningNeedsOneActivePortAndOneDrawingSensor() {
        let phone: ConnectedDevices.Reading = (3.0, 5.2)
        let idle: ConnectedDevices.Reading = (0, 0)
        let charger: ConnectedDevices.Reading = (3.0, 20.0)   // power coming in, not going out
        XCTAssertEqual(ConnectedDevices.learn(active: ["A"], readings: [1: idle, 3: phone])?.sensor, 3)
        XCTAssertEqual(ConnectedDevices.learn(active: ["A"], readings: [3: phone, 4: charger])?.sensor, 3)
        XCTAssertNil(ConnectedDevices.learn(active: ["A", "B"], readings: [3: phone]))
        XCTAssertNil(ConnectedDevices.learn(active: ["A"], readings: [1: phone, 3: phone]))
    }
}

final class PortBadgeTests: XCTestCase {
    func testCircledDigits() {
        XCTAssertEqual(portBadge(1), "①")
        XCTAssertEqual(portBadge(4), "④")
        XCTAssertEqual(portBadge(20), "⑳")
        XCTAssertEqual(portBadge(21), "#21")
        XCTAssertEqual(portBadge(0), "#0")
    }
}

final class InflowTests: XCTestCase {
    func testChargerPortLabels() {
        XCTAssertEqual(Charger(port: "Port-USB-C@4", ratedWatts: 25, watts: 22).portLabel, "USB-C ④")
        XCTAssertEqual(Charger(port: "Port-MagSafe 3@1", ratedWatts: 96, watts: 60).portLabel, "MagSafe")
        XCTAssertEqual(Charger(port: nil, ratedWatts: nil, watts: 5).portLabel, "")
    }

    func testBatteryRate() {
        XCTAssertEqual(batteryRateText(12.9), "+13 W")
        XCTAssertEqual(batteryRateText(-3.2), "−3.2 W")
        // Optimized Battery Charging holds the battery: tiny currents aren't charging.
        XCTAssertEqual(batteryRateText(0.1), "Not charging")
        XCTAssertEqual(batteryRateText(nil), "—")
    }
}

final class EnergyLedgerTests: XCTestCase {
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let noon = 1_790_000_000.0 - 1_790_000_000.0.truncatingRemainder(dividingBy: 86400) + 43200   // 12:00 UTC

    func testGapsAreNotCounted() {
        XCTAssertEqual(EnergyLedger.slice(dt: 10), 10)
        XCTAssertNil(EnergyLedger.slice(dt: 61))    // slept
        XCTAssertNil(EnergyLedger.slice(dt: -5))    // clock went back
        var l = EnergyLedger(since: noon)
        l.add(at: noon, dt: 3600, mac: 10, inflow: nil, battery: nil, devices: [:], charger: nil, calendar: utc)
        XCTAssertTrue(l.days.isEmpty)
    }

    func testAddIntegratesWattsIntoWattHours() {
        var l = EnergyLedger(since: noon)
        // 360 slices of 10 s = one hour at 20 W in, 12 W used, 15 W to an iPhone, 6 W into the battery.
        for i in 0..<360 {
            l.add(at: noon + Double(i) * 10, dt: 10, mac: 27, inflow: 20, battery: 6,
                  devices: ["iPhone": 15], charger: "USB-C ④ · 25 W", calendar: utc)
        }
        let d = l.days.values.first!
        XCTAssertEqual(d.mac, 27, accuracy: 1e-9)
        XCTAssertEqual(d.appsPool, 12, accuracy: 1e-9)     // the iPhone's share isn't any app's
        XCTAssertEqual(d.devices["iPhone"]!, 15, accuracy: 1e-9)
        XCTAssertEqual(d.inflow, 20, accuracy: 1e-9)
        XCTAssertEqual(d.chargers["USB-C ④ · 25 W"]!, 20, accuracy: 1e-9)
        XCTAssertEqual(d.battery, 6, accuracy: 1e-9)
        XCTAssertEqual(d.seconds, 3600)
        XCTAssertEqual(d.peakIn, 20)
    }

    func testDischargingIsNotChargingTheBattery() {
        var l = EnergyLedger(since: noon)
        l.add(at: noon, dt: 10, mac: 8, inflow: nil, battery: -8, devices: [:], charger: nil, calendar: utc)
        XCTAssertEqual(l.days.values.first!.battery, 0)
    }

    func testAppsSplitTheirPoolByEnergyImpact() {
        var l = EnergyLedger(since: noon)
        l.add(at: noon, dt: 36, mac: 100, inflow: nil, battery: nil, devices: [:], charger: nil, calendar: utc)   // 1 Wh
        l.attributeApps(impacts: [:])   // nothing to split by: the pool waits
        XCTAssertEqual(l.days.values.first!.appsPool, 1, accuracy: 1e-9)
        l.attributeApps(impacts: ["Safari": 30, "Xcode": 10, "idle": 0])
        let d = l.days.values.first!
        XCTAssertEqual(d.apps["Safari"]!, 0.75, accuracy: 1e-9)
        XCTAssertEqual(d.apps["Xcode"]!, 0.25, accuracy: 1e-9)
        XCTAssertNil(d.apps["idle"])
        XCTAssertEqual(d.appsPool, 0)
    }

    func testPeriodsAndRecords() {
        var l = EnergyLedger(since: noon - 40 * 86400)
        for daysAgo in [0, 1, 6, 7, 29, 30] {
            let t = noon - Double(daysAgo) * 86400
            l.add(at: t, dt: 36, mac: 100 + Double(daysAgo), inflow: Double(daysAgo), battery: nil,
                  devices: [:], charger: nil, calendar: utc)
        }
        func mac(_ p: StatsPeriod) -> Double { l.totals(for: p, now: noon, calendar: utc).mac }
        XCTAssertEqual(mac(.today), 1.0, accuracy: 1e-9)
        XCTAssertEqual(mac(.week), (300 + 1 + 6) / 100, accuracy: 1e-9)          // today, 1 and 6 days ago
        XCTAssertEqual(mac(.month), (500 + 1 + 6 + 7 + 29) / 100, accuracy: 1e-9)   // up to 29 days ago
        XCTAssertEqual(mac(.all), (600 + 1 + 6 + 7 + 29 + 30) / 100, accuracy: 1e-9)

        let r = l.records
        XCTAssertEqual(r.biggestDay?.wh ?? 0, 1.3, accuracy: 1e-9)
        XCTAssertEqual(r.peakCharging?.watts, 30)
        XCTAssertEqual(r.biggestDay?.day, EnergyLedger.dayKey(noon - 30 * 86400, calendar: utc))
    }

    func testCodableRoundTrip() throws {
        var l = EnergyLedger(since: noon)
        l.add(at: noon, dt: 10, mac: 9, inflow: 20, battery: 5, devices: ["iPhone": 4], charger: "MagSafe · 96 W", calendar: utc)
        l.attributeApps(impacts: ["Safari": 1])
        l.deviceSymbols["iPhone"] = "iphone"
        let back = try JSONDecoder().decode(EnergyLedger.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l)
    }

    func testFormatting() {
        XCTAssertEqual(energyText(0.42), "0.4 Wh")
        XCTAssertEqual(energyText(742.4), "742 Wh")
        XCTAssertEqual(energyText(1240), "1.24 kWh")
        XCTAssertEqual(durationText(45), "45 s")
        XCTAssertEqual(durationText(3 * 3600 + 300), "3 h 5 min")
        XCTAssertEqual(durationText(52 * 3600), "2 d 4 h")
        XCTAssertEqual(approx(3.24), "3.2")
    }
}
