import SwiftUI
import AppKit // NSApp (menu bar : afficher/masquer/quitter)
import os

@main
struct JarvisLocalApp: App {
    @State private var viewModel = AppViewModel()
    private let log = Logger(subsystem: "com.dimitriclaverie.JarvisLocal", category: "app")

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .environment(Settings.shared)
                .frame(minWidth: 800, minHeight: 500)
                .task {
                    await viewModel.loadConversations()
                    logVersion()
                    // Précharge le modèle sur le serveur et le maintient en mémoire :
                    // sans ça, après 5 min d'inactivité, chaque premier message subit
                    // ~20s de chargement à froid (l'endpoint /v1 ne supporte pas keep_alive).
                    OllamaService.shared.startKeepAlive()
                    // MCP (chantier 5) : connexion en fond si activée dans Réglages.
                    // Pourquoi en fond : le spawn des process iMCP prend ~1s et ne doit
                    // pas retarder l'ouverture. Hors-ligne = natif en relais, invisible.
                    if Settings.shared.mcpEnabled {
                        Task {
                            let mcp = MCPToolProvider()
                            await mcp.connectAll()
                            await ToolService.shared.configureMCP(mcp)
                        }
                    }
                }
        }
        .windowResizability(.contentSize)

        // Un assistant qui exige sa fenêtre rate son job : la barre de menu permet
        // de piloter Jarvis (mode vocal !) sans fenêtre au premier plan.
        MenuBarExtra("JarvisLocal", systemImage: "waveform") {
            Button(viewModel.isVoiceMode ? "Quitter le mode vocal" : "Mode vocal mains-libres") {
                Task { await viewModel.toggleVoiceMode() }
            }
            .accessibilityLabel(viewModel.isVoiceMode ? "Quitter le mode vocal" : "Activer le mode vocal mains-libres")
            Divider()
            Button("Afficher Jarvis") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            .accessibilityLabel("Afficher la fenêtre Jarvis")
            Button("Quitter JarvisLocal") {
                NSApp.terminate(nil)
            }
            .accessibilityLabel("Quitter JarvisLocal")
        }
    }

    private func logVersion() {
        let version = Settings.shared.currentVersion
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log.info("JarvisLocal v\(version, privacy: .public) (\(build, privacy: .public))")
        print("🚀 JarvisLocal v\(version) (build \(build))")
    }
}
