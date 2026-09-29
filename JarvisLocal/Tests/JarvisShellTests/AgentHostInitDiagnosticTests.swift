import XCTest
@testable import JarvisShell

/// Diagnostic étape 1 (HUD « serveur injoignable ») : vérifie qu'un
/// `AgentHost.init()` avec l'URL Tailscale réelle ne lève pas hors GUI.
/// Si ce test échoue, la cause est l'init (et `rebuildHost()` pousse à
/// raison `.unreachable`). S'il passe, la cause est ailleurs (binaire
/// obsolète sans `network.client`, probe, ou état initial).
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
