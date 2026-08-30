// swift-tools-version:5.9
import PackageDescription

// ReamCore — the portable, UI-free core of Ream.
//
// Holds the conversion engines (compress-to-target-size, images↔PDF, PDF→images),
// text reflow and plain-text search, and the portable document models. No
// AppKit/SwiftUI imports, so it compiles and is testable headlessly — it is the
// seam that the future CLI (`pdfx`) and the v1.0 content-stream editing engine
// plug into.
//
// NOTE: this package has its own test target, which the app scheme does not
// include. `swift test --package-path ReamCore` (what CI runs) covers it;
// `xcodebuild test` / ⌘U does not.
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
