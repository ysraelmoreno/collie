// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "orq",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "orqd", targets: ["orqd"]),
        .executable(name: "orq", targets: ["orq"]),
        .executable(name: "OrqApp", targets: ["OrqApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.0"),
    ],
    targets: [
        .target(name: "OrqProtocol"),
        .target(name: "OrqCore", dependencies: ["OrqProtocol"]),
        .target(name: "OrqDevice", dependencies: ["OrqProtocol"]),
        .target(name: "OrqTerminal"),
        .target(name: "OrqDaemonKit", dependencies: ["OrqProtocol", "OrqCore", "OrqTerminal", "OrqDevice"]),
        .target(name: "OrqClient", dependencies: ["OrqCore", "OrqProtocol"]),
        .target(name: "OrqCanvas", dependencies: ["OrqCore"]),
        .target(name: "OrqTheme"),
        .target(name: "OrqPlugins", dependencies: ["OrqCore", "OrqProtocol", "OrqDevice", "OrqTheme"]),
        .executableTarget(name: "orqd", dependencies: ["OrqDaemonKit"]),
        .executableTarget(name: "orq", dependencies: ["OrqProtocol", "OrqDaemonKit"]),
        .executableTarget(name: "OrqApp", dependencies: ["OrqClient", "OrqCanvas", "OrqCore", "OrqPlugins", "OrqProtocol", "OrqTheme", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "OrqThemeTests", dependencies: ["OrqTheme"]),
        .testTarget(name: "OrqAppTests", dependencies: ["OrqApp", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "OrqCanvasTests", dependencies: ["OrqCanvas"]),
        .testTarget(name: "OrqProtocolTests", dependencies: ["OrqProtocol"]),
        .testTarget(name: "OrqDeviceTests", dependencies: ["OrqDevice", "OrqProtocol"]),
        .testTarget(name: "OrqCoreTests", dependencies: ["OrqCore"]),
        .testTarget(name: "OrqTerminalTests", dependencies: ["OrqTerminal"]),
        .testTarget(name: "OrqDaemonKitTests", dependencies: ["OrqDaemonKit", "OrqClient", "OrqPlugins"]),
        .testTarget(name: "OrqPluginsTests", dependencies: ["OrqPlugins", "OrqCore", "OrqProtocol", "OrqDevice", "OrqDaemonKit"]),
        .testTarget(name: "OrqClientTests", dependencies: ["OrqClient", "OrqCanvas", "OrqCore", "OrqProtocol", "OrqDaemonKit"]),
        .testTarget(name: "OrqIntegrationTests", dependencies: ["OrqDaemonKit", "OrqCore", "OrqProtocol"]),
    ],
    swiftLanguageModes: [.v6]
)
