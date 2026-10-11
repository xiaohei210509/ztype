// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ztype",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ztype", targets: ["ztype"]),
        .executable(name: "ztypeBench", targets: ["ztypeBench"])
    ],
    targets: [
        .target(name: "ztypeCore"),
        .executableTarget(name: "ztype", dependencies: ["ztypeCore"]),
        .executableTarget(name: "ztypeBench", dependencies: ["ztypeCore"]),
        .testTarget(name: "ztypeCoreTests", dependencies: ["ztypeCore", "ztype"])
    ],
    swiftLanguageModes: [.v5]
)
