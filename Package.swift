// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoTriageMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PhotoTriageMac", targets: ["PhotoTriageApp"])],
    targets: [
        .target(name: "PhotoTriageCore"),
        .executableTarget(name: "PhotoTriageApp", dependencies: ["PhotoTriageCore"]),
        .testTarget(name: "PhotoTriageCoreTests", dependencies: ["PhotoTriageCore"]),
        .testTarget(name: "PhotoTriageAppTests", dependencies: ["PhotoTriageApp"])
    ],
    swiftLanguageModes: [.v5]
)
