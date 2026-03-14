// swift-tools-version:6.2
import PackageDescription

let pkg = Package(name: "ReSwift")
pkg.platforms = [
    .macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10)
]
pkg.products = [
    .library(name: "ReSwift", targets: ["ReSwift"])
]

let pmk: Target = .target(name: "ReSwift")
pmk.path = "ReSwift"
pkg.targets = [
    pmk,
    .testTarget(name: "ReSwiftTests", dependencies: ["ReSwift"], path: "ReSwiftTests")
]
