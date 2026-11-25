// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "collie",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "collied", targets: ["collied"]),
        .executable(name: "collie", targets: ["collie"]),
        .executable(name: "CollieApp", targets: ["CollieApp"]),
        .executable(name: "collie-vizinho", targets: ["collie-vizinho"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.0"),
        // the app's updater (spec 2026-11-25): linked by CollieApp only (scripts/ci/architecture-rules.txt)
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "CollieProtocol"),
        .target(name: "CollieCore", dependencies: ["CollieProtocol"]),
        .target(name: "CollieDevice", dependencies: ["CollieProtocol"]),
        .target(name: "CollieNetwork"),
        .target(name: "CollieTerminal"),
        // the rendered screen (`check --screen`): SwiftTerm brings AppKit, so only collied links it, never the `collie` CLI
        // (enforced: scripts/ci/architecture-rules.txt)
        .target(name: "CollieScreen", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "CollieDaemonKit", dependencies: ["CollieProtocol", "CollieCore", "CollieTerminal", "CollieDevice", "CollieNetwork"]),
        .target(name: "CollieClient", dependencies: ["CollieCore", "CollieProtocol"]),
        .target(name: "CollieCanvas", dependencies: ["CollieCore"]),
        .target(name: "CollieTheme"),
        .target(name: "VizinhoKit"),
        .target(name: "ColliePlugins", dependencies: ["CollieCore", "CollieProtocol", "CollieDevice", "CollieNetwork", "CollieTheme"]),
        .executableTarget(name: "collied", dependencies: ["CollieCore", "CollieDaemonKit", "CollieScreen"]),
        .executableTarget(name: "collie", dependencies: ["CollieClient", "CollieCore", "CollieProtocol", "CollieDaemonKit"]),
        .executableTarget(name: "collie-ctty"),
        .executableTarget(name: "collie-vizinho", dependencies: ["VizinhoKit"]),
        .executableTarget(name: "CollieApp", dependencies: ["CollieClient", "CollieCanvas", "CollieCore", "ColliePlugins", "CollieProtocol", "CollieTheme", .product(name: "SwiftTerm", package: "SwiftTerm"), .product(name: "Sparkle", package: "Sparkle")],
                          // the framework sits in Contents/Frameworks (scripts/bundle-app.sh), the binary in Contents/MacOS
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "CollieThemeTests", dependencies: ["CollieTheme"]),
        .testTarget(name: "VizinhoKitTests", dependencies: ["VizinhoKit"]),
        .testTarget(name: "CollieAppTests", dependencies: ["CollieApp", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "CollieCanvasTests", dependencies: ["CollieCanvas"]),
        .testTarget(name: "CollieProtocolTests", dependencies: ["CollieProtocol"]),
        .testTarget(name: "CollieDeviceTests", dependencies: ["CollieDevice", "CollieProtocol"]),
        .testTarget(name: "CollieNetworkTests", dependencies: ["CollieNetwork"]),
        .testTarget(name: "CollieCoreTests", dependencies: ["CollieCore"]),
        .testTarget(name: "CollieTerminalTests", dependencies: ["CollieTerminal", "collie-ctty"]),
        .testTarget(name: "CollieDaemonKitTests", dependencies: ["CollieDaemonKit", "CollieClient", "ColliePlugins", "CollieNetwork", "CollieScreen"]),
        .testTarget(name: "ColliePluginsTests", dependencies: ["ColliePlugins", "CollieCore", "CollieProtocol", "CollieDevice", "CollieNetwork", "CollieDaemonKit"]),
        .testTarget(name: "CollieClientTests", dependencies: ["CollieClient", "CollieCanvas", "CollieCore", "CollieProtocol", "CollieDaemonKit"]),
        .testTarget(name: "CollieIntegrationTests", dependencies: ["CollieDaemonKit", "CollieCore", "CollieProtocol"]),
    ],
    swiftLanguageModes: [.v6]
)
