// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "openproxy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenProxyCore", targets: ["OpenProxyCore"]),
        .executable(name: "OpenProxyApp", targets: ["OpenProxyApp"]),
        .executable(name: "OpenProxyHelper", targets: ["OpenProxyHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.5"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.1"),
    ],
    targets: [
        .target(
            name: "OpenProxyCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "OpenProxyAppModel", dependencies: ["OpenProxyCore"]),
        .executableTarget(name: "OpenProxyApp", dependencies: ["OpenProxyAppModel"]),
        .executableTarget(name: "OpenProxyHelper", dependencies: ["OpenProxyCore"]),
        .testTarget(name: "OpenProxyCoreTests", dependencies: ["OpenProxyCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "OpenProxyAppTests", dependencies: ["OpenProxyAppModel", "OpenProxyCore"]),
    ],
    swiftLanguageModes: [.v6]
)
