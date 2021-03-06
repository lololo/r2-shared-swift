// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "R2Shared",
    platforms: [
        .macOS(.v10_10), .iOS(.v12), .tvOS(.v9), .watchOS(.v3)
    ],
    products: [
        .library(name: "R2Shared", targets: ["R2Shared"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "1.7.4"),
        .package(url: "https://github.com/cezheng/Fuzi.git", from: "3.1.2"),
        .package(url: "https://github.com/lololo/minizip.git", .branch("master")),
    ],
    targets: [
        .target(name: "R2Shared",
                dependencies: ["SwiftSoup","Minizip","Fuzi"],
                path: "r2-shared-swift",
                exclude: ["Toolkit/Archive/ZIPFoundation.swift"]
        ),
    ]
)
