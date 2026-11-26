// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChronoPlay",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ChronoPlay", targets: ["ChronoPlay"]),
    ],
    targets: [
        // 不含 UI 的邏輯：Spotify API、排序、連續播放引擎
        .target(name: "ChronoPlayCore"),
        // SwiftUI 介面（Liquid Glass）
        .executableTarget(name: "ChronoPlay", dependencies: ["ChronoPlayCore"]),
        .testTarget(name: "ChronoPlayCoreTests", dependencies: ["ChronoPlayCore"]),
    ]
)
