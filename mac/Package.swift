// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Glide",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "glide-host", targets: ["glide-host"]),
        .executable(name: "glide-probe", targets: ["glide-probe"]),
        .executable(name: "glide-viewer", targets: ["glide-viewer"]),
    ],
    targets: [
        .target(name: "GlideCore"),
        // Objective-C shim for the private CGVirtualDisplay classes (runtime lookup, no private
        // symbols linked; docs/VIRTUAL_DISPLAY.md). Builds with the Command Line Tools.
        .target(name: "CGlideVirtualDisplay",
                linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]),
        .executableTarget(name: "glide-host", dependencies: ["GlideCore", "CGlideVirtualDisplay"]),
        .executableTarget(name: "glide-probe", dependencies: ["GlideCore"]),
        // Mac viewer for a Windows host (docs/WINDOWS_HOST.md).
        .executableTarget(name: "glide-viewer", dependencies: ["GlideCore"],
                          linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("VideoToolbox"), .linkedFramework("Carbon")]),
        .executableTarget(name: "glide-selftest", dependencies: ["GlideCore"]),
    ],
    swiftLanguageModes: [.v5]
)
