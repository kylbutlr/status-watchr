// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "StatusWatchrMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "StatusWatchr", targets: ["StatusWatchr"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.5"
        )
    ],
    targets: [
        .executableTarget(
            name: "StatusWatchr",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3"),
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ]),
                .linkedFramework("Network")
            ]
        ),
        .testTarget(
            name: "StatusWatchrTests",
            dependencies: ["StatusWatchr"],
            path: "Tests"
        )
    ]
)
