import SwiftUI
import AppKit
import os
import JarvisCore
import JarvisServices
import JarvisAgent
import JarvisShell

/// L'app est un `LSUIElement` (pas de Dock) qui ne quitte JAMAIS à la
/// fermeture d'une fenêtre : l'agent vit dans la menu bar + le HUD.
/// Plus de `applicationShouldTerminateAfterLastWindowClosed`, plus de ping
/// keep-alive client (le maintien en mémoire est côté serveur, le shell ne
/// fait qu'UN préchauffage si besoin).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Rien à retenir ici : le coordinateur shell possède tout.
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Le coordinateur shell n'est pas retenu ici : voix coupée direct.
        ServiceHosts.tts.stopSpeaking()
        ServiceHosts.stt.cancel()
    }
}

/// Composition root : assemble le shell (hotkey, HUD, voix, monitor) sur le
/// nouveau moteur. L'ancien pipeline (AppViewModel/ContentView) n'est plus
/// branché — suppression phase 4.
@main
struct JarvisLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator: ShellCoordinator
    @Environment(\.openWindow) private var openWindow
    private let log = Logger(subsystem: "com.dimitriclaverie.JarvisLocal", category: "app")

    init() {
        // NE PAS toucher au wrappedValue avant installation : SwiftUI peut
        // jeter l'instance créée dans `init` et en gérer une autre — le menu
        // parlait alors à un coordinateur jamais `boot()`é (panel nil, HUD
        // muet) pendant que l'orphelin sondait en fond. Constaté en réel
        // (showHUD sans jamais un seul `hud show`). On installe explicitement
        // l'instance bootée comme valeur gérée : c'est LA SEULE instance.
        let booted = ShellCoordinator()
        _coordinator = StateObject(wrappedValue: booted)
        // `App` est MainActor-isolé : démarrage explicite ici, une seule fois.
        // Le coordinateur possède tout (hotkey, HUD, voix, monitor).
        booted.boot()
        log.info("Jarvis shell boot")
    }

    var body: some Scene {
        MenuBarExtra("Jarvis", systemImage: "waveform") {
            NotchView(
                isExpanded: $coordinator.homeExpanded,
                unreadCount: $coordinator.unreadCount,
                onTap: { coordinator.toggleHome() }
            )
            
            if coordinator.homeExpanded {
                HomeView(coordinator: coordinator)
                    .frame(minWidth: 400, minHeight: 500)
                    .transition(.opacity)
            }
            
            Divider()
            Button("HUD") {
                coordinator.showHUD()
            }
            .keyboardShortcut("j", modifiers: [.command, .option])
            Button("Historique") { openWindow(id: "history") }
            Button("Réglages") { openWindow(id: "settings") }
            Button("Permissions et onboarding") { openWindow(id: "onboarding") }
            Divider()
            Button("Quitter Jarvis") { NSApp.terminate(nil) }
        }

        Window("Historique Jarvis", id: "history") {
            HistoryView(store: FileTranscriptStore(directory: AgentHost.transcriptsDirectory()))
                .frame(minWidth: 700, minHeight: 450)
        }
        .defaultPosition(.center)

        Window("Réglages Jarvis", id: "settings") {
            ShellSettingsView(settings: $coordinator.settings, coordinator: coordinator)
                .onChange(of: coordinator.settings.ollamaURL) { coordinator.rebuildHost() }
                .onChange(of: coordinator.settings.model) { coordinator.rebuildHost() }
        }
        .defaultPosition(.center)

        Window("Bienvenue dans Jarvis", id: "onboarding") {
            OnboardingView(onTestHotkey: {})
        }
        .defaultPosition(.center)
    }
}
