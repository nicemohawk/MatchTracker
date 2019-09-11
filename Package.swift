// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "Packages",
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "Packages",
//            type: .static,
            targets: ["Packages"]),
        ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "4.8.2"),
        .package(url: "https://github.com/nicemohawk/Locksmith.git", from: "4.0.1"),
        ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "Packages",
            dependencies: ["Alamofire", "Locksmith"],
            path: "Packages"
        )
    ]
)
