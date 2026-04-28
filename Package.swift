// swift-tools-version: 5.9
import PackageDescription
//Swift SDK for **[ART — A Realtime Tech communication,](https://arealtimetech.com/)**, a realtime messaging platform providing WebSocket-based channels, presence tracking, end-to-end encrypted messaging, and CRDT-backed shared objects.
let package = Package(
    name: "ArtAdk",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(name: "ArtAdk", targets: ["ArtAdk"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/bitmark-inc/tweetnacl-swiftwrap",
            from: "1.1.0"
        )
    ],
    targets: [
        .target(
            name: "ArtAdk",
            dependencies: [
                .product(name: "TweetNacl", package: "tweetnacl-swiftwrap")
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]

)
