// swift-tools-version:5.10
// Spike only (phase 0 of the network interceptor). Not part of the main Collie package.
import PackageDescription

let package = Package(
    name: "spike-proxy",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
    ],
    targets: [
        // Trivial executable linking NIO + NIOSSL + X509 + Crypto: measures what the stack adds to build time and binary size.
        .executableTarget(name: "spike-nio-size", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        // subject_hash_old check (uses SwiftASN1 + Crypto); X509 stays linked so it is the size baseline without NIO.
        .executableTarget(name: "spike-hash", dependencies: [
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
    ]
)
