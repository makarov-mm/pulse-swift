// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "PulseCore", targets: ["PulseCore"])]
var targets: [Target] = [
    .target(name: "PulseCore"),
    .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore"])
]

#if os(macOS)
products.append(.executable(name: "MakarovPulse", targets: ["MakarovPulse"]))
targets += [
    .systemLibrary(name: "DarwinHeaders"),
    .target(name: "PulseMac", dependencies: ["PulseCore", "DarwinHeaders"]),
    .executableTarget(name: "MakarovPulse", dependencies: ["PulseCore", "PulseMac"]),
    .testTarget(name: "PulseMacTests", dependencies: ["PulseMac", "PulseCore"])
]
#endif

let package = Package(
    name: "MakarovPulse",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
