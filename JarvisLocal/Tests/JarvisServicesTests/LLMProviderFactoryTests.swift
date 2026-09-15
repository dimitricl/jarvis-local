@testable import JarvisServices
import JarvisCore
import Observation
import XCTest

/// Étape 2 : la factory construit des providers configurés — aucun singleton
/// caché, aucune lecture du Settings concret dans le chemin de production.
/// Ces tests prouvent l'injection SANS réseau (makeURL / makeRequestBody sont purs).

@Observable
final class StubSettings: AppSettingsProtocol {
    var ollamaURL: String
    var model: String
    var fastModel = "stub-fast"
    var reasoningEffort = "none"
    var numCtx = 8192
    var maxTokens = 1024
    var temperature = 0.5
    var maxToolCallsPerTurn = 3
    var ttsEnabled = false
    var voiceEnabled = false
    var ttsVoiceIdentifier = ""
    var bargeInEnabled = false
    var mcpEnabled = false
    var imcpPath = ""
    var launchAtLogin = false
    var isCheckingUpdate = false
    var updateCheckError: String?
    var updateAvailable = false
    var ollamaHostIsLocal: Bool { true }
    var currentVersion: String { "stub" }
    var frenchVoiceOptions: [VoiceOption] { [] }
    func checkForUpdates(repoOwner: String, repoName: String) async {}

    init(ollamaURL: String = "http://stub:11434", model: String = "stub-model") {
        self.ollamaURL = ollamaURL
        self.model = model
    }
}

final class LLMProviderFactoryTests: XCTestCase {
    func testMakeDefaultReturnsOllamaBackedProvider() {
        let provider = LLMProviderFactory.makeDefault(settings: Settings.shared)
        XCTAssertTrue(provider is OllamaService)
    }

    func testMakeWithExplicitKind() {
        let provider = LLMProviderFactory.make(kind: .ollama, settings: Settings.shared)
        XCTAssertTrue(provider is OllamaService)
    }

    func testFactoryBuildsFreshInstancesNotSingletons() {
        let a = LLMProviderFactory.makeOllama(settings: Settings.shared)
        let b = LLMProviderFactory.makeOllama(settings: Settings.shared)
        XCTAssertFalse(a === b, "la factory construit une instance — elle ne retourne pas un singleton caché")
    }

    func testKindRegistryListsOllamaOnly() {
        XCTAssertEqual(LLMProviderKind.allCases, [.ollama])
        XCTAssertFalse(LLMProviderKind.ollama.displayName.isEmpty)
    }

    func testInjectedSettingsDriveEndpoint() {
        let service = OllamaService(settings: StubSettings(ollamaURL: "http://fake-host:9999"))
        XCTAssertEqual(service.makeURL()?.absoluteString, "http://fake-host:9999/v1/chat/completions")
    }

    func testInjectedSettingsDoNotMutateSingleton() {
        let before = Settings.shared.ollamaURL
        let service = OllamaService(settings: StubSettings(ollamaURL: "http://fake-host:9999"))
        _ = service.makeURL()
        XCTAssertEqual(Settings.shared.ollamaURL, before, "l'injection ne doit pas toucher au singleton")
    }

    func testRequestBodyUsesInjectedOptions() {
        let stub = StubSettings()
        stub.temperature = 0.1
        stub.maxTokens = 111
        stub.numCtx = 2222
        stub.reasoningEffort = "low"
        let service = OllamaService(settings: stub)
        // NOTE : le modèle arrive en paramètre (le chemin streamChat y passe
        // settings.model) ; les options, elles, sont lues sur le settings injecté.
        let body = service.makeRequestBody(model: "whatever", messages: [], stream: false, tools: nil)
        let options = body["options"] as? [String: Any]
        XCTAssertEqual(options?["temperature"] as? Double, 0.1)
        XCTAssertEqual(options?["num_predict"] as? Int, 111)
        XCTAssertEqual(options?["num_ctx"] as? Int, 2222)
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
    }
}
