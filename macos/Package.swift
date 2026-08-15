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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5")
    ],
    targets: [
        .target(name: "TTSModInstallerCore"),
        .executableTarget(
            name: "TTSModInstallerApp",
            dependencies: [
                "TTSModInstallerCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
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
