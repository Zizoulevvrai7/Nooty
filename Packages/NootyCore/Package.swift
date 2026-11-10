// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NootyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "NootyCore", targets: ["NootyCore"])],
    targets: [
        .target(name: "NootyCore"),
        .testTarget(name: "NootyCoreTests", dependencies: ["NootyCore"]),
    ]
)
