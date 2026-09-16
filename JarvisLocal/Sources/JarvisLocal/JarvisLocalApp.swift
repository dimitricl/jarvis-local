import SwiftUI
import AppKit // NSApplicationDelegate (quitter à la fermeture de la fenêtre)
import os
import JarvisCore
import JarvisServices
import JarvisUI

/// L'app ne vit plus en arrière-plan : fermer la dernière fenêtre quitte.
/// (Avant, la MenuBarExtra maintenait le process en vie fenêtre fermée.)
/// Le delegate seul laissait un délai perceptible entre la croix rouge et la
/// sortie (mesuré : le teardown lui-même prend ~1 s) : on double donc avec une
/// sortie explicite dès qu'il ne reste plus aucune fenêtre visible ou
/// miniaturisée — une fenêtre miniaturisée compte comme "toujours là".
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Nettoyage synchrone posé par l'App (retient l'instance Ollama factory).
    /// Main thread uniquement (init + willTerminate) — pas de concurrence.
    static var onWillTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Coupe tout ce qui peut retenir la sortie : voix, keep-alive réseau,
    /// serveurs MCP enfants (sinon orphelins). Best-effort synchrone —
    /// le process sort de toute façon, mais sans traîner.
    func applicationWillTerminate(_ notification: Notification) {
        Self.onWillTerminate?()
        ServiceHosts.tts.stopSpeaking()
        ServiceHosts.stt.cancel()
        Task { await ToolService.shared.configureMCP(nil) }
    }

    @objc private func windowWillClose(_ note: Notification) {
        // Pas de délai : la fenêtre en cours de fermeture est connue via
        // note.object, on l'exclut du comptage et on quitte immédiatement
        // s'il ne reste rien de visible ou miniaturisé.
        let closing = note.object as? NSWindow
        let alive = NSApp.windows.contains { w in
            if let c = closing, w === c { return false }
            return w.isVisible || w.isMiniaturized
        }
        if !alive { NSApp.terminate(nil) }
    }
}

/// Composition root : seul endroit de l'app qui connaît à la fois les concrets
/// (JarvisServices) et l'UI (JarvisUI) pour les assembler. Les targets Sources
/// ne se référencent jamais dans ce sens — la frontière est le graphe de
/// dépendances Package.swift, pas une convention.
@main
struct JarvisLocalApp: App {
    private let settings = Settings.shared
    /// Instance LLM retenue par l'app : construite par la factory (aucun singleton
    /// caché), injectée au ViewModel sous `any LLMProvider`, et son keep-alive
    /// démarre sur cette même instance — pas sur un `OllamaService.shared` séparé.
    private let ollama: OllamaService
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel: AppViewModel
    private let log = Logger(subsystem: "com.dimitriclaverie.JarvisLocal", category: "app")

    init() {
        let ollama = LLMProviderFactory.makeOllama(settings: Settings.shared)
        self.ollama = ollama
        // Coupe le keep-alive (warm-up + ping /4 min) à la sortie : sinon la
        // boucle réseau retient le teardown.
        AppDelegate.onWillTerminate = { [ollama] in ollama.stopKeepAlive() }
        _viewModel = State(initialValue: AppViewModel(
            db: ServiceHosts.store,
            ollama: ollama,
            tools: ServiceHosts.tools,
            audio: ServiceHosts.tts,
            stt: ServiceHosts.stt,
            settings: Settings.shared
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings)
                .environment(viewModel)
                .frame(minWidth: 800, minHeight: 500)
                .task {
                    await viewModel.loadConversations()
                    logVersion()
                    // Précharge le modèle sur le serveur et le maintient en mémoire :
                    // sans ça, après 5 min d'inactivité, chaque premier message subit
                    // ~20s de chargement à froid (l'endpoint /v1 ne supporte pas keep_alive).
                    // Démarré sur l'instance factory retenue par l'app (même config que le chat).
                    ollama.startKeepAlive()
                    // MCP (chantier 5) : connexion en fond si activée dans Réglages.
                    // Pourquoi en fond : le spawn des process iMCP prend ~1s et ne doit
                    // pas retarder l'ouverture. Hors-ligne = natif en relais, invisible.
                    if settings.mcpEnabled {
                        Task {
                            let mcp = MCPToolProvider()
                            await mcp.connectAll()
                            await ToolService.shared.configureMCP(mcp)
                        }
                    }
                }
        }
        .windowResizability(.contentSize)
        // Chrome Liquid Glass : la toolbar fusionne avec la title bar, le verre
        // système s'étend sur toute la zone haute (phase 1).
        .windowToolbarStyle(.unified)

        // Pas de MenuBarExtra : l'app ne reste PAS en arrière-plan fenêtre
        // fermée — AppDelegate quitte à la fermeture de la dernière fenêtre.
        // Le mode vocal reste disponible tant que la fenêtre est ouverte.
    }

    private func logVersion() {
        let version = settings.currentVersion
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log.info("JarvisLocal v\(version, privacy: .public) (\(build, privacy: .public))")
        print("🚀 JarvisLocal v\(version) (build \(build))")
    }
}
