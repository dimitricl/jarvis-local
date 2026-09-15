import Foundation
import Observation

/// Option de voix TTS sous forme de données pures. Pourquoi pas AVSpeechSynthesisVoice :
/// c'est un type AVFoundation — l'exposer ici forcerait JarvisCore à importer
/// AVFoundation pour un seul picker. La conversion vit dans Settings (Services).
public struct VoiceOption: Sendable, Hashable {
    public let identifier: String
    public let name: String
    public let language: String
    public let qualityLabel: String

    public init(identifier: String, name: String, language: String, qualityLabel: String) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.qualityLabel = qualityLabel
    }
}

/// L0 — contrat de configuration applicative.
///
/// Tranché (étape 1) : PAS d'exception silencieuse. Settings fait de l'I/O
/// persistante (UserDefaults à chaque didSet, SMAppService au toggle
/// launchAtLogin) — exactement comme DatabaseService fait du SQLite. Le concret
/// (`final class Settings`) vit donc dans JarvisServices ; l'UI et les tests
/// ne retiennent que ce protocol.
///
/// Vues SwiftUI : `SettingsView<S: AppSettingsProtocol>` générique + `@Bindable`
/// (les bindings exigent des key paths concrets, impossibles sur existentiel).
/// Seules les propriétés lues/écrites hors Services figurent ici ; le reste
/// (`availableFrenchVoices`, `selectedVoice`, `isLocalHostname`...) reste sur le
/// concret, accessible dans Services et via `@testable` dans ses tests.
public protocol AppSettingsProtocol: AnyObject, Observable {
    var ollamaURL: String { get set }
    var model: String { get set }
    var fastModel: String { get set }
    var reasoningEffort: String { get set }
    var numCtx: Int { get set }
    var maxTokens: Int { get set }
    var temperature: Double { get set }
    var ttsEnabled: Bool { get set }
    var voiceEnabled: Bool { get set }
    var ttsVoiceIdentifier: String { get set }
    var bargeInEnabled: Bool { get set }
    var mcpEnabled: Bool { get set }
    var imcpPath: String { get set }
    var launchAtLogin: Bool { get set }
    var isCheckingUpdate: Bool { get set }
    var updateCheckError: String? { get set }
    var updateAvailable: Bool { get set }
    var ollamaHostIsLocal: Bool { get }
    var currentVersion: String { get }
    var frenchVoiceOptions: [VoiceOption] { get }
    func checkForUpdates(repoOwner: String, repoName: String) async
}

public extension AppSettingsProtocol {
    func checkForUpdates() async {
        await checkForUpdates(repoOwner: "dimitricl", repoName: "jarvis-local")
    }
}
