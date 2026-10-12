// swift-tools-version:5.9
import PackageDescription

// Offline replay of a diagnostics bundle (session.json exported from the app) through the CURRENT tracking, merging and
// grouping code. run.sh copies the real Core sources next to main.swift. Not part of the app.
let package = Package(
    name: "StoreShelfReplay",
    targets: [
        .executableTarget(name: "replay", path: "Sources/replay"),
    ]
)
