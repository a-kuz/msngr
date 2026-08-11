// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MsngrKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MsngrCrypto", targets: ["MsngrCrypto"]),
        .library(name: "MsngrCore", targets: ["MsngrCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(name: "MsngrCrypto"),
        .target(
            name: "MsngrCore",
            dependencies: [
                "MsngrCrypto",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "MsngrCryptoTests", dependencies: ["MsngrCrypto"]),
        .testTarget(name: "MsngrCoreTests", dependencies: ["MsngrCore"]),
    ]
)
