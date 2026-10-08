// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BatteryAnalysis",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BatteryAnalysis", path: "Sources/BatteryAnalysis"),
        .testTarget(name: "BatteryAnalysisTests", dependencies: ["BatteryAnalysis"], path: "Tests/BatteryAnalysisTests"),
    ]
)
