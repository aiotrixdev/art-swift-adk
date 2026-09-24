// swift-tools-version: 5.9
import PackageDescription
import Foundation


let hasLocalTests = FileManager.default.fileExists(
    atPath: Context.packageDirectory + "/Tests/ArtAdkTests"
)

let package: Package = Package(
    name: "ArtAdk",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(name: "ArtAdk", targets: ["ArtAdk"]),
        .library(name: "ArtAdkNotifications", targets: ["ArtAdkNotifications"]),
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
        .target(
            name: "ArtAdkNotifications",
            dependencies: ["ArtAdk"]
        ),
    ] + (hasLocalTests ? [
        .testTarget(
            name: "ArtAdkTests",
            dependencies: ["ArtAdk", "ArtAdkNotifications"]
        ),
    ] : []),
    swiftLanguageVersions: [.v5]

)
