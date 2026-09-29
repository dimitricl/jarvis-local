import XCTest
@testable import JarvisShell

/// Diagnostic étape 1 (HUD « serveur injoignable ») : vérifie qu'un
/// `AgentHost.init()` avec l'URL Tailscale réelle ne lève pas hors GUI.
/// Si ce test échoue, la cause est l'init. S'il passe, la cause est
/// ailleurs (binaire obsolète, probe, ou état initial).
final class AgentHostInitDiagnosticTests: XCTestCase {
    func testInitAvecURLTailscaleNeLevePas() throws {
        var s = ShellSettings(defaults: UserDefaults(suiteName: "jarvis-diagnostic-\(UUID().uuidString)")!)
        s.ollamaURL = "http://100.101.108.111:11434"
        s.model = "gemma4:e4b"
        do {
            _ = try AgentHost(runtime: AgentHost.Runtime(settings: s))
        } catch {
            XCTFail("AgentHost.init a levé avec l'URL Tailscale : \(error)")
        }
    }
}

/// Verrous étape 3 (points 4-5) : un échec d'init pousse un état DISTINCT
/// du réseau (`.unavailable`, jamais le triangle `.unreachable` menteur),
/// sans écraser un run en cours.
final class AgentErrorStateTests: XCTestCase {
    func testAgentErrorDonneEtatDistinctDeUnreachable() {
        let viaReduce = HUDReduce.reduce(
            state: .idle, action: .connection(.agentError(detail: "boom")), runActive: false)
        if case .unavailable(let detail) = viaReduce {
            XCTAssertEqual(detail, "boom")
        } else {
            XCTFail("attendu .unavailable, obtenu \(viaReduce)")
        }
        // Un run en cours prime : l'erreur agent ne l'écrase pas.
        let acting = HUDState.acting(tool: "bash", target: "ls")
        XCTAssertEqual(
            HUDReduce.reduce(state: acting, action: .connection(.agentError(detail: "x")), runActive: true),
            acting)
    }

    @MainActor
    func testRebuildHostEchecInitNeMentPasUnreachable() {
        var s = ShellSettings(defaults: UserDefaults(suiteName: "jarvis-diagnostic-\(UUID().uuidString)")!)
        s.ollamaURL = "http://example.com:11434" // hôte distant non-TLS → init lève
        let coordinator = ShellCoordinator(settings: s)
        coordinator.rebuildHost()
        if case .unavailable(let detail) = coordinator.hudState {
            XCTAssertFalse(detail.isEmpty)
        } else {
            XCTFail("attendu .unavailable (pas .unreachable), obtenu \(coordinator.hudState)")
        }
    }

    @MainActor
    func testSondeAutoNArrachePasLaSaisie() async {
        var s = ShellSettings(defaults: UserDefaults(suiteName: "jarvis-diagnostic-\(UUID().uuidString)")!)
        s.ollamaURL = "http://127.0.0.1:9" // valide mais injoignable (connexion refusée)
        s.model = "gemma4:e4b"
        let coordinator = ShellCoordinator(settings: s)
        coordinator.showHUD()
        XCTAssertEqual(coordinator.hudState, .transcribing(text: ""))
        await coordinator.probeAndWarmup() // sonde auto : ne touche pas à la saisie
        XCTAssertEqual(coordinator.hudState, .transcribing(text: ""))
        await coordinator.probeAndWarmup(force: true) // « Réessayer » : dit la vérité
        if case .unreachable = coordinator.hudState { return }
        XCTFail("attendu .unreachable après retry forcé, obtenu \(coordinator.hudState)")
    }

    @MainActor
    func testShowHUDSansBootCreeLePanel() {
        // Instance jamais boot()ée (cas SwiftUI : wrappedValue jeté dans init)
        // : showHUD doit auto-créer le panneau au lieu de rester muet.
        let coordinator = ShellCoordinator(settings: ShellSettings(
            defaults: UserDefaults(suiteName: "jarvis-diagnostic-\(UUID().uuidString)")!))
        XCTAssertFalse(coordinator.panelExists)
        coordinator.showHUD()
        XCTAssertTrue(coordinator.panelExists)
        XCTAssertEqual(coordinator.hudState, .transcribing(text: ""))
    }
}
