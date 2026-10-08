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
