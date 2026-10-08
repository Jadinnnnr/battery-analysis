import Foundation
import IOKit

/// Reads total system power ("PSTR") from the SMC, about once a second resolution, no admin rights.
/// The key is undocumented, so callers fall back to battery telemetry when it isn't available.
final class SMCPower {
    private var conn: io_connect_t = 0
    private var keySize: UInt32 = 0
    private static let key: UInt32 = 0x50535452          // "PSTR"
    private static let floatType: UInt32 = 0x666C7420    // "flt "

    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
        var b = [UInt8](repeating: 0, count: 80)
        Self.put32(&b, 0, Self.key); b[42] = 9          // kSMCGetKeyInfo
        guard let info = call(b), Self.get32(info, 32) == Self.floatType else {
            IOServiceClose(conn)
            return nil
        }
        keySize = Self.get32(info, 28)
    }

    deinit { IOServiceClose(conn) }

    func read() -> Double? {
        var b = [UInt8](repeating: 0, count: 80)
        Self.put32(&b, 0, Self.key); Self.put32(&b, 28, keySize); b[42] = 5   // kSMCReadKey
        guard let out = call(b) else { return nil }
        let w = Double(Array(out[48..<52]).withUnsafeBytes { $0.load(as: Float.self) })
        return w.isFinite && w >= 0 ? w : nil
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

    private let smc = SMCPower()
    private var timer: Timer?

    var sensorAvailable: Bool { smc != nil }

    /// Starts, restarts or stops polling to match the current settings.
    func configure() {
        timer?.invalidate()
        timer = nil
        let settings = Settings.shared
        guard settings.showWatts, smc != nil else { watts = nil; return }
        let interval = Double(settings.wattsInterval)
        refresh()
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in LiveWatts.shared.refresh() }
        }
        t.tolerance = interval * 0.1   // let macOS coalesce the wakeup with others
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Only publishes when the displayed text changes, so unchanged readings redraw nothing.
    private func refresh() {
        guard let w = smc?.read() else { return }
        if watts.map(wattsText) != wattsText(w) { watts = w }
    }
}
