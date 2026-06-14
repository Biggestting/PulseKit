// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PulseKit",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8)],
    products: [
        .library(name: "PulseKit", targets: ["PulseKit"]),
    ],
    targets: [
        .target(name: "PulseKit"),
    ]
)
