import Foundation
import IOKit

/// What kind of device is on a port, for its icon.
enum DeviceKind: Equatable {
    case iPhone, iPad, watch, airPods, phone, mac, storage, camera, audio, printer, input, other

    var symbol: String {
        switch self {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .watch: "applewatch"
        case .airPods: "airpods"
        case .phone: "candybarphone"
        case .mac: "laptopcomputer"
        case .storage: "externaldrive"
        case .camera: "web.camera"
        case .audio: "headphones"
        case .printer: "printer"
        case .input: "keyboard"
        case .other: "cable.connector"
        }
    }

    /// From the device's name, then its USB interface classes (8 storage, 14 video, 1 audio,
    /// 6 still image, 7 printer, 3 keyboard/mouse).
    static func guess(name: String, interfaceClasses: Set<Int>) -> DeviceKind {
        let n = name.lowercased()
        if n.contains("iphone") { return .iPhone }
        if n.contains("ipad") { return .iPad }
        if n.contains("watch") { return .watch }
        if n.contains("airpods") { return .airPods }
        if ["pixel", "galaxy", "android", "phone"].contains(where: n.contains) { return .phone }
        if n.contains("macbook") || n.hasPrefix("mac ") { return .mac }
        if interfaceClasses.contains(8) { return .storage }
        if interfaceClasses.contains(14) || interfaceClasses.contains(6) { return .camera }
        if interfaceClasses.contains(1) { return .audio }
        if interfaceClasses.contains(7) { return .printer }
        if interfaceClasses.contains(3) { return .input }
        return .other
    }
}

/// A device plugged into one of the Mac's USB-C ports, and the power the port is giving it.
struct ConnectedDevice: Identifiable, Equatable {
    let id: String          // the port, e.g. "Port-USB-C@4"
    let port: Int           // macOS's number for that port, the 4 in "@4"
    let name: String        // "iPhone", or "iPhone, T7 Shield" behind a hub
    let kind: DeviceKind
    let watts: Double

    /// Equal when they'd look the same, so small changes in a reading don't redraw anything.
    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.port == b.port && a.name == b.name && a.kind == b.kind && deviceWattsText(a.watts) == deviceWattsText(b.watts)
    }
}

func deviceWattsText(_ w: Double) -> String { w < 0.1 ? "<0.1 W" : wattsText(w) }

/// A port number as a circled digit ("④"), short enough for the menu bar. Plain text, so it
/// draws where SF Symbols in a menu bar label don't.
func portBadge(_ n: Int) -> String {
    guard (1...20).contains(n), let c = UnicodeScalar(0x2460 + n - 1) else { return "#\(n)" }
    return String(Character(c))
}

/// Reads the IORegistry: the USB-C ports and the USB devices behind them. No admin rights.
enum PortScanner {
    struct Port {
        let id: String          // "Port-USB-C@4"
        let number: Int         // the 4 in "@4"
        let controller: Int?    // index of the USB controller wired to it (from its "hpmN" parent)
        let active: Bool
        let partnerName: String?   // name the device gave during USB-C negotiation, e.g. "iPhone"
    }

    struct USBDevice {
        let controller: Int     // top byte of locationID
        let name: String
        let kind: DeviceKind
        let isHub: Bool
    }

    static func usbCPorts() -> [Port] {
        var out: [Port] = []
        forEach(matching: "AppleHPMInterface") { e in
            guard prop(e, "PortTypeDescription") as String? == "USB-C",
                  let id: String = prop(e, "PortDescription") else { return }
            out.append(Port(id: id, number: prop(e, "PortNumber") ?? 0, controller: hpmIndex(e),
                            active: prop(e, "ConnectionActive") ?? false, partnerName: prop(e, "SOPMfgString")))
        }
        return out
    }

    /// A port that's powering the Mac: its USB-C power negotiation has a winning option.
    struct PowerSource {
        let port: String        // "Port-USB-C@4" or "Port-MagSafe 3@1"
        let ratedWatts: Double? // what the charger agreed to supply, e.g. 24.9 for 9 V × 2.77 A
    }

    static func powerSources() -> [PowerSource] {
        var out: [PowerSource] = []
        forEach(matching: "IOPortFeaturePowerSource") { e in
            guard let option: [String: Any] = prop(e, "WinningPowerSourceOption"),
                  let desc: String = prop(e, "Description"),
                  let port = desc.components(separatedBy: "/").first else { return }
            out.append(PowerSource(port: port, ratedWatts: (option["Max Power (mW)"] as? Int).map { Double($0) / 1000 }))
        }
        return out
    }

    static func usbDevices() -> [USBDevice] {
        var out: [USBDevice] = []
        forEach(matching: "IOUSBHostDevice") { e in
            guard let loc: UInt32 = prop(e, "locationID") else { return }
            let name: String = prop(e, "USB Product Name") ?? prop(e, "kUSBProductString") ?? "USB device"
            let deviceClass: Int = prop(e, "bDeviceClass") ?? 0
            var classes = Set<Int>()
            var it: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(e, kIOServicePlane, &it) == KERN_SUCCESS {
                defer { IOObjectRelease(it) }
                while case let child = IOIteratorNext(it), child != 0 {
                    if let c: Int = prop(child, "bInterfaceClass") { classes.insert(c) }
                    IOObjectRelease(child)
                }
            }
            out.append(USBDevice(controller: Int(loc >> 24), name: name,
                                 kind: .guess(name: name, interfaceClasses: classes), isHub: deviceClass == 9))
        }
        return out
    }

    /// Each USB-C port sits under a power controller named "hpmN", and N matches the index of
    /// the USB controller for that port (hpm3 → usb-drd3 → devices at locationID 0x03xxxxxx).
    private static func hpmIndex(_ entry: io_registry_entry_t) -> Int? {
        var e = entry
        IOObjectRetain(e)
        defer { IOObjectRelease(e) }
        for _ in 0..<6 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(e, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(e)
            e = parent
            var buf = [CChar](repeating: 0, count: 128)   // io_name_t
            IORegistryEntryGetName(e, &buf)
            let name = String(cString: buf)
            if name.hasPrefix("hpm"), let n = Int(name.dropFirst(3)) { return n }
        }
        return nil
    }

    private static func forEach(matching cls: String, _ body: (io_registry_entry_t) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let e = IOIteratorNext(it), e != 0 {
            body(e)
            IOObjectRelease(e)
        }
    }

    private static func prop<T>(_ e: io_registry_entry_t, _ key: String) -> T? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
    }
}

/// Devices plugged into the USB-C ports and how much power each port is giving them, from the
/// SMC's per-port current and voltage sensors ("D1JI"/"D1JV" and so on). Kept separate from
/// Tracker and LiveWatts so only the views showing devices redraw when a reading changes.
@MainActor
final class ConnectedDevices: ObservableObject {
    static let shared = ConnectedDevices()
    @Published private(set) var devices: [ConnectedDevice] = []

    typealias Reading = (amps: Double, volts: Double)
    private let sensors: [Int: (current: SMC.Key, voltage: SMC.Key)]
    private let hasPorts: Bool
    /// Port → sensor pairs seen in practice (see `learn`), saved between launches.
    private var learned: [String: Int]
    private let learnedKey = "portSensors"

    /// Whether this Mac has both USB-C ports and per-port power sensors.
    var available: Bool { hasPorts && !sensors.isEmpty }

    private init() {
        var found: [Int: (SMC.Key, SMC.Key)] = [:]
        if let smc = SMC.shared {
            for n in 1...9 {
                if let i = smc.floatKey("D\(n)JI"), let v = smc.floatKey("D\(n)JV") { found[n] = (i, v) }
            }
        }
        sensors = found
        hasPorts = !PortScanner.usbCPorts().isEmpty
        learned = UserDefaults.standard.dictionary(forKey: learnedKey) as? [String: Int] ?? [:]
    }

    func refresh() {
        guard available else { return }
        let ports = PortScanner.usbCPorts()
        var active = ports.filter(\.active)
        // A port charging the Mac isn't a device, even if it still has the last device's name.
        if !active.isEmpty {
            let charging = Set(PortScanner.powerSources().map(\.port))
            active.removeAll { charging.contains($0.id) }
        }
        // Nothing plugged in: skip the sensor reads entirely.
        guard !active.isEmpty else {
            if !devices.isEmpty { devices = [] }
            return
        }
        var readings: [Int: Reading] = [:]
        for (n, k) in sensors {
            if let a = SMC.shared?.read(k.current), let v = SMC.shared?.read(k.voltage) { readings[n] = (a, v) }
        }
        if let (port, sensor) = Self.learn(active: active.map(\.id), readings: readings), learned[port] != sensor {
            learned[port] = sensor
            UserDefaults.standard.set(learned, forKey: learnedKey)
        }

        let map = Self.sensorMap(ports: ports, sensors: Array(sensors.keys), learned: learned)
        let usb = PortScanner.usbDevices()
        var out: [ConnectedDevice] = []
        for p in active.sorted(by: { $0.number < $1.number }) {
            guard let n = map[p.id], let r = readings[n] else { continue }
            // Above USB's 5 V the port is taking power in: that's a charger, not a device.
            if r.volts > 6 { continue }
            let onPort = usb.filter { $0.controller == p.controller }
            let named = onPort.filter { !$0.isHub }
            let name: String, kind: DeviceKind
            if let first = named.first {
                name = named.map(\.name).joined(separator: ", "); kind = first.kind
            } else if let s = p.partnerName, !s.isEmpty {
                name = s; kind = .guess(name: s, interfaceClasses: [])
            } else {
                name = onPort.isEmpty ? "USB-C device" : "USB hub"; kind = .other
            }
            out.append(ConnectedDevice(id: p.id, port: p.number, name: name, kind: kind, watts: max(0, r.amps * r.volts)))
        }
        if out != devices { devices = out }
    }

    /// Which sensor belongs to which port. By default the USB-C ports in order take the sensors
    /// in order (on an M5 MacBook Pro: USB-C@1 → D1, @2 → D2, @4 → D3, MagSafe → D4). That's an
    /// observation, not documented, so pairs actually seen in use override it.
    nonisolated static func sensorMap(ports: [PortScanner.Port], sensors: [Int], learned: [String: Int]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (p, n) in zip(ports.sorted { $0.number < $1.number }, sensors.sorted()) { map[p.id] = n }
        for (port, n) in learned where sensors.contains(n) {
            // A learned pair takes the sensor away from whichever port was guessed for it.
            if let other = map.first(where: { $0.value == n && $0.key != port })?.key { map[other] = nil }
            map[port] = n
        }
        return map
    }

    /// With exactly one port in use and exactly one sensor showing a device drawing power, they
    /// must belong together.
    nonisolated static func learn(active: [String], readings: [Int: Reading]) -> (port: String, sensor: Int)? {
        let drawing = readings.filter { $0.value.amps > 0.05 && $0.value.volts > 0 && $0.value.volts <= 6 }
        guard active.count == 1, drawing.count == 1, let n = drawing.first?.key else { return nil }
        return (active[0], n)
    }
}

/// The charger powering the Mac, if any, and how much power is coming in from it.
struct Charger: Equatable {
    let port: String?       // "Port-USB-C@4", or nil if no port claims it
    let ratedWatts: Double?
    let watts: Double       // coming in right now

    /// "MagSafe", "USB-C ④", or "" when the port isn't known.
    var portLabel: String {
        guard let port else { return "" }
        if port.contains("MagSafe") { return "MagSafe" }
        if let n = port.split(separator: "@").last.flatMap({ Int($0) }) { return "USB-C \(portBadge(n))" }
        return ""
    }

    /// "USB-C ④ · 25 W", from whichever parts are known; nil when neither is.
    var detail: String? {
        let parts = [portLabel, ratedWatts.map { "\(Int($0.rounded())) W" } ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func == (a: Self, b: Self) -> Bool {
        a.port == b.port && a.ratedWatts?.rounded() == b.ratedWatts?.rounded() && wattsText(a.watts) == wattsText(b.watts)
    }
}

/// Power coming into the Mac from a charger, from the SMC's DC-in sensors: "PDTR" (watts) and
/// "VD0R" (volts, near zero when nothing is connected). Both match what the battery reports
/// as SystemPowerIn, but update every reading instead of every minute or so.
@MainActor
final class PowerInflow: ObservableObject {
    static let shared = PowerInflow()
    @Published private(set) var charger: Charger?

    private let power = SMC.shared?.floatKey("PDTR")
    private let voltage = SMC.shared?.floatKey("VD0R")

    var available: Bool { power != nil && voltage != nil }

    func refresh() {
        guard let power, let voltage, let v = SMC.shared?.read(voltage) else { return }
        // Chargers supply 5 V or more; on battery this reads a few hundredths of a volt.
        guard v > 3, let w = SMC.shared?.read(power) else {
            if charger != nil { charger = nil }
            return
        }
        let source = PortScanner.powerSources().first
        let c = Charger(port: source?.port, ratedWatts: source?.ratedWatts, watts: max(0, w))
        if c != charger { charger = c }
    }
}
