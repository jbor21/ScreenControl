// swift-tools-version: 5.9
//
// Secondary build path for people without Xcode's IDE (Command Line Tools + `swift build` on macOS).
// The Xcode project is the primary way to build; it produces a proper .app bundle. This target
// builds the same sources into a bare executable that still runs as a menu bar app.
import PackageDescription

let package = Package(
    name: "ScreenControl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenControl",
            path: "ScreenControl"
        )
    ]
)
