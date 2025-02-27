// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReSwift",
    platforms: [.iOS(.v17), .macOS(.v10_15), .tvOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "ReSwift", targets: ["ReSwift"])
    ],
    targets: [
        .target(
            name: "ReSwift",
            path: "ReSwift"
        ),
        .testTarget(
            name: "ReSwiftTests",
            dependencies: ["ReSwift"],
            path: "ReSwiftTests"
        )
    ]
)
