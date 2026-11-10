// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YANCMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "YANCMac", targets: ["YANCMac"]),
        .library(name: "ProDOSKit", targets: ["ProDOSKit"]),
    ],
    targets: [
        .target(name: "ProDOSKit"),
        .executableTarget(name: "YANCMac", dependencies: ["ProDOSKit"]),
        // Engine tests as a plain program, so they run without Xcode:  swift run SelfTest
        .executableTarget(name: "SelfTest", dependencies: ["ProDOSKit"]),
    ]
)
