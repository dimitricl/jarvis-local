// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JarvisLocal",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "JarvisLocal",
            path: "JarvisLocal",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "JarvisLocalTests",
            dependencies: ["JarvisLocal"]
        )
    ]
)
