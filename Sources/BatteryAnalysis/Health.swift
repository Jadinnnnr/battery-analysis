import AppKit
import Foundation
import IOKit

struct BatteryHealth: Equatable {
    var maxCapacity: Int?     // percent of original design capacity
    var cycles: Int?
    var systemWatts: Double?  // whole-system power draw right now
    var adapterWatts: Int?    // rating of the connected charger

    var condition: String {
        guard let m = maxCapacity else { return "Unknown" }
        return m >= 80 ? "Normal" : "Service Recommended"
    }
}

enum HealthReader {
    static func read() -> BatteryHealth? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }

        var h = BatteryHealth()
        h.cycles = d["CycleCount"] as? Int
        if let bd = d["BatteryData"] as? [String: Any],
           let design = bd["DesignCapacity"] as? Int, design > 0,
           let nominal = (bd["NominalChargeCapacity"] as? Int) ?? (d["AppleRawMaxCapacity"] as? Int) {
            h.maxCapacity = min(100, Int((Double(nominal) / Double(design) * 100).rounded()))
        }
        if let t = d["PowerTelemetryData"] as? [String: Any], let load = t["SystemLoad"] as? Int, load > 0 {
            h.systemWatts = Double(load) / 1000
        } else if let v = d["Voltage"] as? Int, let a = d["Amperage"] as? NSNumber {
            // Negative currents come back as unsigned 64-bit two's complement (e.g. 18446744073709551101 = -515 mA).
            let mA = Int64(bitPattern: a.uint64Value)
            h.systemWatts = abs(Double(v) * Double(mA)) / 1_000_000
        }
        if let ad = d["AdapterDetails"] as? [String: Any] { h.adapterWatts = ad["Watts"] as? Int }
        return h
    }
}

/// Read-only: the app never changes Low Power Mode. It only notices whether it's on.
enum LowPower {
    static func isEnabled() -> Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// Opens System Settings at the Battery pane so the user can switch it on themselves.
    @MainActor
    static func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
