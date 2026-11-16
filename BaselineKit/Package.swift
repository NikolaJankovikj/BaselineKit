// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BaselineKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BaselineKit", targets: ["HealthData", "Forecasting", "Insights", "Persistence"]),
    ],
    targets: [
        .target(name: "HealthData"),
        .target(
            name: "Forecasting",
            dependencies: ["HealthData"],
            // Copied as is and compiled on first use: `swift build` has no Core ML compiler.
            resources: [.copy("Resources/Chronos2Small.mlpackage")]
        ),
        .target(name: "Insights", dependencies: ["HealthData", "Forecasting"]),
        .target(name: "Persistence", dependencies: ["HealthData", "Forecasting", "Insights"]),
        .testTarget(name: "HealthDataTests", dependencies: ["HealthData"]),
        .testTarget(
            name: "ForecastingTests",
            dependencies: ["Forecasting"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
        .testTarget(name: "InsightsTests", dependencies: ["Insights", "Forecasting", "HealthData"]),
    ]
)
