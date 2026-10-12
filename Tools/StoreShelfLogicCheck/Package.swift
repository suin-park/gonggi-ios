// swift-tools-version:5.9
import PackageDescription

// Linux pre-check of the pure 매장 logic (Gonggi/Features/StoreShelf/Core). run.sh copies the real sources into
// Sources/Gonggi and the real tests into Tests/GonggiTests, then runs `swift test`. Not part of the app.
let package = Package(
    name: "StoreShelfLogic",
    targets: [
        .target(name: "Gonggi", path: "Sources/Gonggi"),
        .testTarget(name: "GonggiTests", dependencies: ["Gonggi"], path: "Tests/GonggiTests"),
    ]
)
