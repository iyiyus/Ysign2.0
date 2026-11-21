// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YSign",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "SigningEngine", targets: ["SigningEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.18"),
        .package(url: "https://github.com/tsolomko/SWCompression.git", exact: "4.8.0"),
    ],
    targets: [
        .target(
            name: "SigningEngine",
            dependencies: ["ZIPFoundation", "SWCompression"],
            path: "Sources/SigningEngine"
        ),
        .testTarget(
            name: "SigningEngineTests",
            dependencies: ["SigningEngine"],
            path: "Tests/SigningEngineTests"
        ),
    ]
)
