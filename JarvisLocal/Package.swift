// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JarvisLocal",
    platforms: [.macOS(.v26)],
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
        // L0 — types purs du moteur d'agent v1.0 : JSONValue, Message,
        // ToolSpec, AgentEvent. Zéro dépendance. Swift 6 dès le départ.
        .target(
            name: "JarvisKit",
            path: "Sources/JarvisKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // L1 — moteur d'agent headless (boucle, registre, permissions,
        // compaction, transcript). SANS SwiftUI/AppKit. Swift 6.
        .target(
            name: "JarvisAgent",
            dependencies: ["JarvisKit"],
            path: "Sources/JarvisAgent",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // L1 — providers LLM (OpenAI-compatible / Ollama, Anthropic à venir).
        // Sélection par config, jamais de callback UI. Swift 6.
        .target(
            name: "JarvisProviders",
            dependencies: ["JarvisKit"],
            path: "Sources/JarvisProviders",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Phase 0 — harnais d'évaluation agent (v1.0). Kit testable (pur + I/O
        // injectable) + CLI fine. Aucune IP/host en dur : tout vient des
        // réglages / variables d'environnement / argv.
        .target(
            name: "JarvisEvalKit",
            path: "Sources/JarvisEvalKit"
        ),
        .executableTarget(
            name: "JarvisEval",
            dependencies: ["JarvisEvalKit"],
            path: "Sources/JarvisEval"
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
        .testTarget(
            name: "JarvisEvalKitTests",
            dependencies: ["JarvisEvalKit"],
            path: "Tests/JarvisEvalKitTests"
        ),
        .testTarget(
            name: "JarvisKitTests",
            dependencies: ["JarvisKit"],
            path: "Tests/JarvisKitTests"
        ),
        .testTarget(
            name: "JarvisAgentTests",
            dependencies: ["JarvisAgent", "JarvisKit"],
            path: "Tests/JarvisAgentTests"
        ),
        .testTarget(
            name: "JarvisProvidersTests",
            dependencies: ["JarvisProviders", "JarvisAgent", "JarvisKit"],
            path: "Tests/JarvisProvidersTests"
        ),
    ],
    // La migration Swift 6 exige d'abord un conteneur Sendable pour les arguments
    // JSON des outils, aujourd'hui représentés par [String: Any].
    swiftLanguageModes: [.v5]
)
