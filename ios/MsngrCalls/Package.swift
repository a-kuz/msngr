// swift-tools-version: 5.9
import PackageDescription

// A package of its own so the WebRTC binary is linked only where a call can
// happen: the app. MsngrKit and the notification extension never pull it.
let package = Package(
    name: "MsngrCalls",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MsngrCalls", targets: ["MsngrCalls"])
    ],
    dependencies: [
        .package(path: "../MsngrKit"),
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "151.0.0"),
    ],
    targets: [
        .target(
            name: "MsngrCalls",
            dependencies: [
                .product(name: "MsngrCore", package: "MsngrKit"),
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        )
    ]
)
