// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Glide",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "glide-host", targets: ["glide-host"]),
        .executable(name: "glide-probe", targets: ["glide-probe"]),
    ],
    targets: [
        .target(name: "GlideCore"),
        .executableTarget(name: "glide-host", dependencies: ["GlideCore"]),
        .executableTarget(name: "glide-probe", dependencies: ["GlideCore"]),
        .executableTarget(name: "glide-selftest", dependencies: ["GlideCore"]),
    ],
    swiftLanguageModes: [.v5]
)
