// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "Shine", targets: ["Shine"])],
    targets: [
        .target(name: "Shine", cSettings: [.unsafeFlags(["-w"])]),
    ]
)
