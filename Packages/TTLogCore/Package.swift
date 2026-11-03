// swift-tools-version: 5.9
// 画面や端末機能に依存しない純粋なロジック。Linux でも `swift test` が通るように保つ。
import PackageDescription

let package = Package(
    name: "TTLogCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TTLogCore", targets: ["TTLogCore"]),
    ],
    targets: [
        .target(name: "TTLogCore"),
        .testTarget(name: "TTLogCoreTests", dependencies: ["TTLogCore"]),
    ]
)
