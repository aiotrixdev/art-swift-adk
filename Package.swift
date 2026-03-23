// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ADK",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(name: "ADK", targets: ["ADK"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/bitmark-inc/tweetnacl-swiftwrap",
            from: "1.1.0"
        )
    ],
    targets: [
        .target(
            name: "ADK",
            dependencies: [
                .product(name: "TweetNacl", package: "tweetnacl-swiftwrap")
            ]
        ),
    ]

)
