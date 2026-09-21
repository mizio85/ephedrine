// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ephedrine",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Ephedrine",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
