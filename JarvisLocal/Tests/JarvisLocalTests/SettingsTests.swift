@testable import JarvisLocal
import XCTest
import AVFoundation

final class JarvisLocalSettingsTests: XCTestCase {

    var settings: Settings!

    override func setUp() async throws {
        try await super.setUp()
        settings = Settings.shared
    }

    // MARK: - TTSEngine

    func testTTSEngineLabels() {
        XCTAssertEqual(TTSEngine.system.label, "Synthèse macOS")
        XCTAssertEqual(TTSEngine.edgeTTS.label, "Edge TTS (en ligne)")
    }

    func testTTSEngineAllCases() {
        XCTAssertEqual(TTSEngine.allCases.count, 2)
        XCTAssertTrue(TTSEngine.allCases.contains(.system))
        XCTAssertTrue(TTSEngine.allCases.contains(.edgeTTS))
    }

    func testTTSEngineRawValues() {
        XCTAssertEqual(TTSEngine(rawValue: "system"), .system)
        XCTAssertEqual(TTSEngine(rawValue: "edgeTTS"), .edgeTTS)
        XCTAssertNil(TTSEngine(rawValue: "unknown"))
    }

    // MARK: - Voices

    func testSelectedVoiceReturnsFrenchVoiceOrBestAvailable() {
        let voice = settings.selectedVoice
        if let v = voice {
            XCTAssertTrue(v.language.hasPrefix("fr-") || !settings.availableFrenchVoices.isEmpty == false)
        }
        // Si des voix FR existent, selectedVoice doit en retourner une
        if !settings.availableFrenchVoices.isEmpty {
            XCTAssertNotNil(voice)
            XCTAssertTrue(voice!.language.hasPrefix("fr-"))
        }
    }

    func testSelectedVoiceFallsBackToFirstWhenIdentifierInvalid() {
        let original = settings.ttsVoiceIdentifier
        defer { settings.ttsVoiceIdentifier = original }

        if settings.availableFrenchVoices.isEmpty { return } // pas de voix dispo sur la machine de test

        settings.ttsVoiceIdentifier = "invalid.voice.identifier"
        XCTAssertEqual(settings.selectedVoice?.identifier, settings.availableFrenchVoices.first?.identifier)
    }

    func testSelectedVoiceReturnsMatchingVoiceForValidIdentifier() {
        let original = settings.ttsVoiceIdentifier
        defer { settings.ttsVoiceIdentifier = original }

        guard let first = settings.availableFrenchVoices.first else { return }
        settings.ttsVoiceIdentifier = first.identifier
        XCTAssertEqual(settings.selectedVoice?.identifier, first.identifier)
    }

    // MARK: - Version

    func testCurrentVersionIsNonEmpty() {
        XCTAssertFalse(settings.currentVersion.isEmpty)
    }

    // MARK: - Defaults

    func testDefaultsAreSaneAfterInit() {
        // Ces valeurs doivent toujours être définies après init (UserDefaults ou fallback)
        XCTAssertFalse(settings.ollamaURL.isEmpty)
        XCTAssertFalse(settings.model.isEmpty)
        XCTAssertFalse(settings.reasoningEffort.isEmpty)
    }
}
