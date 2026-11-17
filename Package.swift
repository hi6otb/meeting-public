// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Interview",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Interview", targets: ["Interview"])],
    targets: [
        .executableTarget(name: "Interview", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "InterviewTests", dependencies: ["Interview"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
