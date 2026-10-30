import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import X509

// Size probe only: touch each module so the linker keeps it, then exit.
let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let tls = try NIOSSLContext(configuration: .makeClientConfiguration())
let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
print("nio-size ok", tls, head.method, Certificate.Version.v3)
try group.syncShutdownGracefully()
