// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MatchTrackerKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MatchTrackerKit",
            targets: ["MatchTrackerKit"]
        )
    ],
    targets: [
        .target(
            name: "MatchTrackerKit"
        ),
        .testTarget(
            name: "MatchTrackerKitTests",
            dependencies: ["MatchTrackerKit"]
        )
    ]
)
