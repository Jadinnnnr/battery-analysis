import Foundation

/// One snapshot: battery state plus the energy impact of each top app.
struct Sample: Codable {
    var t: Double            // unix time
    var b: Double            // battery percent 0-100
    var ac: Bool             // plugged in
    var a: [String: Double]  // app name -> energy impact

    var date: Date { Date(timeIntervalSince1970: t) }
}

struct BatteryInfo: Equatable {
    var percent: Double = 0
    var charging = false
    var pluggedIn = false
    var minutesRemaining: Int? = nil
    var hasBattery = true
}

enum TimeRange: String, CaseIterable, Identifiable {
    case hour = "1 hour", day = "24 hours", week = "7 days", month = "30 days"
    var id: String { rawValue }
    var seconds: Double {
        switch self {
        case .hour: 3600
        case .day: 86400
        case .week: 604800
        case .month: 2592000
        }
    }
    /// How long an analysis of this range may be reused while new samples arrive. A 30 s sample
    /// barely moves a week or a month, and rescanning one is the most expensive thing the UI does.
    var cacheAge: Double { self == .week || self == .month ? 300 : 0 }
}

struct SeriesPoint: Identifiable {
    var id: String { "\(app)|\(date.timeIntervalSince1970)" }
    let date: Date
    let app: String
    let value: Double
}

struct RankedApp: Identifiable {
    var id: String { name }
    let name: String
    let share: Double
}

struct Analysis {
    var ranked: [RankedApp] = []
    var seriesNames: [String] = []
    var series: [SeriesPoint] = []
    var battery: [(date: Date, percent: Double)] = []
    var sampleCount = 0
}
