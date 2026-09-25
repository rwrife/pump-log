// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PumpKit",
    platforms: [
        .iOS("26.0"),
        .macOS(.v15),
    ],
    products: [
        .library(name: "PumpKit", targets: ["PumpKit"]),
    ],
    targets: [
        .target(name: "PumpKit"),
        .testTarget(name: "PumpKitTests", dependencies: ["PumpKit"]),
    ]
)
