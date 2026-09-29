// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PumpStore",
    platforms: [
        .iOS("26.0"),
        .macOS(.v15),
    ],
    products: [
        .library(name: "PumpStore", targets: ["PumpStore"]),
        .library(name: "PumpStoreTestSupport", targets: ["PumpStoreTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(path: "../PumpKit"),
    ],
    targets: [
        .target(
            name: "PumpStore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "PumpKit"]
        ),
        .target(name: "PumpStoreTestSupport", dependencies: ["PumpStore"]),
        .executableTarget(
            name: "fixture-seed",
            dependencies: ["PumpStore", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Tools/fixture-seed"
        ),
        .testTarget(
            name: "PumpStoreTests",
            dependencies: [
                "PumpStore",
                "PumpStoreTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            exclude: ["Fixtures/v1.sqlite"]
        ),
    ]
)
