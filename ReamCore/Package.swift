// swift-tools-version:5.9
import PackageDescription

// ReamCore — the portable, UI-free core of Ream.
//
// This is intentionally a near-empty stub for v0.1. It is the seam that the
// future CLI (`pdfx`) and the v1.0 content-stream editing engine plug into.
// Keeping it as a standalone SwiftPM library (no AppKit/SwiftUI imports) means
// it can compile and be reused headlessly on any platform later.
let package = Package(
    name: "ReamCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "ReamCore",
            targets: ["ReamCore"]
        )
    ],
    targets: [
        .target(
            name: "ReamCore"
        ),
        .testTarget(
            name: "ReamCoreTests",
            dependencies: ["ReamCore"]
        )
    ]
)
