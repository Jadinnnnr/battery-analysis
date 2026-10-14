import Foundation
import IOKit

/// Reads float sensors from the SMC, no admin rights. The keys are undocumented and vary by
/// model, so every key is looked up first and callers handle it being missing.
@MainActor
final class SMC {
    static let shared = SMC()

    struct Key {
        let code: UInt32
        let size: UInt32
    }

    private var conn: io_connect_t = 0
    private static let floatType: UInt32 = 0x666C7420    // "flt "

    private init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(conn) }

    /// A float key such as "PSTR", or nil if this Mac doesn't have it.
    func floatKey(_ name: String) -> Key? {
        let code = name.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var b = [UInt8](repeating: 0, count: 80)
        Self.put32(&b, 0, code); b[42] = 9          // kSMCGetKeyInfo
        guard let info = call(b), Self.get32(info, 32) == Self.floatType else { return nil }
        return Key(code: code, size: Self.get32(info, 28))
    }

    func read(_ key: Key) -> Double? {
        var b = [UInt8](repeating: 0, count: 80)
        Self.put32(&b, 0, key.code); Self.put32(&b, 28, key.size); b[42] = 5   // kSMCReadKey
        guard let out = call(b) else { return nil }
        let v = Double(Array(out[48..<52]).withUnsafeBytes { $0.load(as: Float.self) })
        return v.isFinite ? v : nil
    }

    // SMCKeyData_t is 80 bytes; fields are written at their C offsets by hand because Swift
    // doesn't guarantee C layout for nested structs. Selector 2 = kSMCHandleYPCEvent.
    private func call(_ input: [UInt8]) -> [UInt8]? {
        var inp = input, out = [UInt8](repeating: 0, count: 80), outSize = 80
        let r = IOConnectCallStructMethod(conn, 2, &inp, 80, &out, &outSize)
        return (r == KERN_SUCCESS && out[40] == 0) ? out : nil
    }
    private static func put32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        for i in 0..<4 { b[off + i] = UInt8((v >> (8 * UInt32(i))) & 0xff) }
    }
    private static func get32(_ b: [UInt8], _ off: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(b[off + $1]) << (8 * UInt32($1)) }
    }
}

/// The live wattage shown in the menu bar. Kept out of Tracker on purpose: only views that
/// observe this object redraw on a new reading. When it lived on Tracker, every update rebuilt
/// the whole interface (~33 ms each); isolated it's ~5-7 ms (measured).
@MainActor
final class LiveWatts: ObservableObject {
    static let shared = LiveWatts()
    @Published private(set) var watts: Double?

    /// Total system power ("PSTR"), about once a second resolution.
    private let pstr = SMC.shared?.floatKey("PSTR")
    private var timer: Timer?

    var sensorAvailable: Bool { pstr != nil }

    /// Starts, restarts or stops polling to match the current settings. The same tick also
    /// updates connected devices, so they share one wakeup.
    func configure() {
        timer?.invalidate()
        timer = nil
        let settings = Settings.shared
        let devices = ConnectedDevices.shared
        if !settings.showWatts { watts = nil }
        guard (settings.showWatts && pstr != nil) || devices.available else { return }
        let interval = Double(settings.wattsInterval)
        tick()
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in LiveWatts.shared.tick() }
        }
        t.tolerance = interval * 0.1   // let macOS coalesce the wakeup with others
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let devices = ConnectedDevices.shared
        devices.refresh()
        // The total is also read while devices are connected, so it can be shown next to them.
        if Settings.shared.showWatts || !devices.devices.isEmpty {
            refresh()
        } else if watts != nil {
            watts = nil
        }
    }

    /// Only publishes when the displayed text changes, so unchanged readings redraw nothing.
    private func refresh() {
        guard let pstr, let w = SMC.shared?.read(pstr), w >= 0 else { return }
        if watts.map(wattsText) != wattsText(w) { watts = w }
    }
}
