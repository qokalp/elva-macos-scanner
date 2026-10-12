// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ElvaScanner",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PixmaKit", targets: ["PixmaKit"]),
        .executable(name: "elvascan", targets: ["elvascan"]),
        .executable(name: "ElvaScanner", targets: ["ElvaScanner"]),
    ],
    targets: [
        // Native Canon BJNP (network) + PIXMA scan protocol driver. No Canon software required.
        .target(name: "PixmaKit"),
        // Command-line tool: discovery, identity check and scanning. Useful for diagnostics.
        .executableTarget(name: "elvascan", dependencies: ["PixmaKit"]),
        // SwiftUI app.
        .executableTarget(
            name: "ElvaScanner",
            dependencies: ["PixmaKit"],
            exclude: ["Resources"]
        ),
        .testTarget(name: "PixmaKitTests", dependencies: ["PixmaKit"]),
    ],
    swiftLanguageModes: [.v5]
)
