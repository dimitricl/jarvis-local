// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JarvisLocal",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Parseur DOM réel pour search_web / read_url.
        // Pourquoi SwiftSoup et pas regex : le markup DDG change souvent ;
        // un sélecteur CSS casse proprement (0 résultat) au lieu de
        // produire des faux positifs silencieux comme une regex sur HTML brut.
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "JarvisLocal",
            dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")],
            path: "JarvisLocal",
            exclude: ["Info.plist", "Resources"]
        ),
        .testTarget(
            name: "JarvisLocalTests",
            dependencies: ["JarvisLocal"]
        )
    ]
)
