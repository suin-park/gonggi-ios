// swift-tools-version:5.9
import PackageDescription

// Linux-only pre-check of the pure product-capture logic (box auto placement, product-extent rule): the CI job copies
// the real app sources into Sources/Gonggi and the real tests into Tests/GonggiTests, then runs `swift test`.
// Nothing here is part of the app. The module is called Gonggi so the app's `@testable import Gonggi` works unchanged.
let package = Package(
    name: "GonggiObjectLogic",
    targets: [
        .target(name: "Gonggi", path: "Sources/Gonggi"),
        .testTarget(name: "GonggiTests", dependencies: ["Gonggi"], path: "Tests/GonggiTests"),
    ]
)
