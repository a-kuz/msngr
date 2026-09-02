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
        // the SDK pins its own WebRTC build (LiveKitWebRTC, LKRTC-prefixed
        // classes); the 1:1 transport runs on that same build, so the app
        // links one WebRTC
        .package(url: "https://github.com/livekit/client-sdk-swift.git", exact: "2.16.0"),
    ],
    targets: [
        .target(
            name: "MsngrCalls",
            dependencies: [
                .product(name: "MsngrCore", package: "MsngrKit"),
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ]
        )
    ]
)
