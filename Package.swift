// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIRadio",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(name: "AIRadioCore"),
        .target(
            name: "AIRadioInfra",
            dependencies: ["AIRadioCore", "Yams"]
        ),
        .target(name: "AIRadioTestSupport", dependencies: ["AIRadioCore"]),
        .executableTarget(name: "AIRadioApp", dependencies: ["AIRadioCore", "AIRadioInfra"]),
        .testTarget(name: "AIRadioCoreTests", dependencies: ["AIRadioCore", "AIRadioTestSupport"]),
        .testTarget(name: "AIRadioInfraTests", dependencies: ["AIRadioInfra", "AIRadioTestSupport"]),
    ]
)
