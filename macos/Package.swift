// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TTSModInstaller",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "TTSModInstallerCore", targets: ["TTSModInstallerCore"]),
        .executable(name: "TTSModInstallerApp", targets: ["TTSModInstallerApp"]),
        .executable(name: "TTSModInstallerCoreTests", targets: ["TTSModInstallerCoreTests"])
    ],
    targets: [
        .target(name: "TTSModInstallerCore"),
        .executableTarget(
            name: "TTSModInstallerApp",
            dependencies: ["TTSModInstallerCore"]
        ),
        .executableTarget(
            name: "TTSModInstallerCoreTests",
            dependencies: ["TTSModInstallerCore"],
            path: "Tests/TTSModInstallerCoreTests",
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
