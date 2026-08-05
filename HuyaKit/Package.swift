// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "HuyaKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "HuyaKit", targets: ["HuyaKit"]),
        .executable(name: "huyaproxy", targets: ["huyaproxy"])
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire", from: "5.0.0"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift", from: "1.0.0"),
        .package(url: "https://github.com/utahiosmac/Marshal", from: "1.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.76.1")
    ],
    targets: [
        .target(
            name: "HuyaKit",
            dependencies: [
                .product(name: "Alamofire", package: "Alamofire"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
                .product(name: "Marshal", package: "Marshal"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "huyaproxy",
            dependencies: [
                "HuyaKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio")
            ]
        )
    ]
)
