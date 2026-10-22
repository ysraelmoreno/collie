// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "collie",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "collied", targets: ["collied"]),
        .executable(name: "collie", targets: ["collie"]),
        .executable(name: "CollieApp", targets: ["CollieApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.0"),
    ],
    targets: [
        .target(name: "CollieProtocol"),
        .target(name: "CollieCore", dependencies: ["CollieProtocol"]),
        .target(name: "CollieDevice", dependencies: ["CollieProtocol"]),
        .target(name: "CollieTerminal"),
        .target(name: "CollieDaemonKit", dependencies: ["CollieProtocol", "CollieCore", "CollieTerminal", "CollieDevice"]),
        .target(name: "CollieClient", dependencies: ["CollieCore", "CollieProtocol"]),
        .target(name: "CollieCanvas", dependencies: ["CollieCore"]),
        .target(name: "CollieTheme"),
        .target(name: "ColliePlugins", dependencies: ["CollieCore", "CollieProtocol", "CollieDevice", "CollieTheme"]),
        .executableTarget(name: "collied", dependencies: ["CollieDaemonKit"]),
        .executableTarget(name: "collie", dependencies: ["CollieProtocol", "CollieDaemonKit"]),
        .executableTarget(name: "CollieApp", dependencies: ["CollieClient", "CollieCanvas", "CollieCore", "ColliePlugins", "CollieProtocol", "CollieTheme", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "CollieThemeTests", dependencies: ["CollieTheme"]),
        .testTarget(name: "CollieAppTests", dependencies: ["CollieApp", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "CollieCanvasTests", dependencies: ["CollieCanvas"]),
        .testTarget(name: "CollieProtocolTests", dependencies: ["CollieProtocol"]),
        .testTarget(name: "CollieDeviceTests", dependencies: ["CollieDevice", "CollieProtocol"]),
        .testTarget(name: "CollieCoreTests", dependencies: ["CollieCore"]),
        .testTarget(name: "CollieTerminalTests", dependencies: ["CollieTerminal"]),
        .testTarget(name: "CollieDaemonKitTests", dependencies: ["CollieDaemonKit", "CollieClient", "ColliePlugins"]),
        .testTarget(name: "ColliePluginsTests", dependencies: ["ColliePlugins", "CollieCore", "CollieProtocol", "CollieDevice", "CollieDaemonKit"]),
        .testTarget(name: "CollieClientTests", dependencies: ["CollieClient", "CollieCanvas", "CollieCore", "CollieProtocol", "CollieDaemonKit"]),
        .testTarget(name: "CollieIntegrationTests", dependencies: ["CollieDaemonKit", "CollieCore", "CollieProtocol"]),
    ],
    swiftLanguageModes: [.v6]
)
