// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ext4Mounter",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Ext4Mounter",       targets: ["App"]),
        .executable(name: "com.ext4mounter.helper", targets: ["PrivilegedHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", from: "0.35.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.4"),
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
            dependencies: [
                "Shared",
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
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
    ,
    swiftLanguageModes: [.v5]
)
