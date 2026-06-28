// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ext4Mounter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ext4Mounter",       targets: ["App"]),
        .executable(name: "com.ext4mounter.helper", targets: ["PrivilegedHelper"]),
    ],
    targets: [
        // Main SwiftUI App
        .executableTarget(
            name: "App",
            dependencies: ["Engine", "Shared"],
            path: "Sources/App"
        ),
        // VM Engine (VZ.framework)
        .target(
            name: "Engine",
            dependencies: ["Shared"],
            path: "Sources/Engine"
        ),
        // Shared types / XPC protocol
        .target(
            name: "Shared",
            dependencies: [],
            path: "Sources/Shared"
        ),
        // Privileged Helper (XPC daemon, runs as root)
        .executableTarget(
            name: "PrivilegedHelper",
            dependencies: ["Shared"],
            path: "Sources/PrivilegedHelper"
        ),
    ]
)
