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
        // L0 — contrats purs : models + protocols, zéro dépendance UI/DB/réseau.
        // Ne doit importer que Foundation (+ Observation pour le protocol Settings).
        .target(
            name: "JarvisCore",
            path: "Sources/JarvisCore"
        ),
        // L1 — capacités : actors + I/O (SQLite, réseau, EventKit, MCP...).
        // SEUL module autorisé à toucher la persistance et les services système.
        .target(
            name: "JarvisServices",
            dependencies: [
                "JarvisCore",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources/JarvisServices"
        ),
        // L3 — interfaces : Views + ViewModels. Dépend de JarvisCore UNIQUEMENT.
        // Toute référence à JarvisServices (DatabaseService, SQLite, Settings
        // concret, OllamaService, ToolService...) casse à la compilation, par
        // construction du graphe — pas par convention. Ne jamais ajouter
        // JarvisServices aux dépendances de cette target.
        .target(
            name: "JarvisUI",
            dependencies: ["JarvisCore"],
            path: "Sources/JarvisUI"
        ),
        // Composition root : seul endroit qui assemble concrets (Services) + UI.
        .executableTarget(
            name: "JarvisLocal",
            dependencies: ["JarvisCore", "JarvisServices", "JarvisUI"],
            path: "Sources/JarvisLocal"
        ),
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"],
            path: "Tests/JarvisCoreTests"
        ),
        .testTarget(
            name: "JarvisServicesTests",
            dependencies: ["JarvisServices", "JarvisCore"],
            path: "Tests/JarvisServicesTests"
        ),
        .testTarget(
            name: "JarvisLocalTests",
            dependencies: ["JarvisUI", "JarvisServices", "JarvisCore"],
            path: "Tests/JarvisLocalTests"
        ),
    ]
)
