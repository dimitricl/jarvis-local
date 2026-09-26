import Foundation
import Observation
import AppKit
import UserNotifications
import JarvisCore

/// Coordinateur de gestion des messages et streaming (extraits d'AppViewModel).
/// Responsabilité unique : flux de messages, streaming, tool trace, notifications.
/// L'état observable reste dans AppViewModel ; ce coordinateur opère via callbacks.
@MainActor
@Observable
public final class MessageCoordinator {
    // MARK: - État (miroir de l'état VM pour les callbacks)

    public var messages: [Message] = []
    public var streamingText = ""
    public var isStreaming = false
    public var isToolRunning = false
    public var currentToolName = ""
    public var toolTrace: [ToolTraceEntry] = []

    /// Trace des outils appelés pendant le tour en cours.
    public struct ToolTraceEntry: Identifiable, Equatable {
        public let id = UUID()
        public let name: String
        public var status: String // "…", "✓", "✗"
    }

    // MARK: - Dépendances

    private let turnRunner: ConversationTurnRunner
    private let db: any PersistentStore
    private let audio: any TTSEngine
    private let stt: any STTEngine
    private let settings: any AppSettingsProtocol
    private let onError: (String) -> Void
    private let onConfirmationRequest: (ToolConfirmationRequest?) -> Void
    private let getConfirmationRequest: () -> ToolConfirmationRequest?
    private let getInputText: () -> String
    private let setInputText: (String) -> Void

    /// Crée le coordinateur.
    init(
        turnRunner: ConversationTurnRunner,
        db: any PersistentStore,
        audio: any TTSEngine,
        stt: any STTEngine,
        settings: any AppSettingsProtocol,
        onError: @escaping (String) -> Void,
        onConfirmationRequest: @escaping (ToolConfirmationRequest?) -> Void,
        getConfirmationRequest: @escaping () -> ToolConfirmationRequest?,
        getInputText: @escaping () -> String,
        setInputText: @escaping (String) -> Void
    ) {
        self.turnRunner = turnRunner
        self.db = db
        self.audio = audio
        self.stt = stt
        self.settings = settings
        self.onError = onError
        self.onConfirmationRequest = onConfirmationRequest
        self.getConfirmationRequest = getConfirmationRequest
        self.getInputText = getInputText
        self.setInputText = setInputText
    }

    private var streamTask: Task<Void, Never>?

    // MARK: - Envoi message

    /// Point d'entrée appelé depuis l'UI. Crée un Task annulable pour permettre stopStreaming().
    public func sendMessage() async {
        let text = getInputText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Si déjà en streaming, on coupe l'envoi en cours
        if isStreaming {
            stopStreaming()
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        setInputText("")

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runConversationTurn(userText: text)
        }
        streamTask = task
        await task.value
        streamTask = nil
    }

    /// Exécute un tour de conversation via le TurnRunner.
    private func runConversationTurn(userText: String) async {
        await turnRunner.run(userText: userText)
    }

    /// Annule réellement l'envoi en cours (requête réseau + boucle de tools).
    public func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        isToolRunning = false
        streamingText = ""

        // Résout une confirmation en attente pour débloquer la boucle
        if let pending = getConfirmationRequest() {
            onConfirmationRequest(nil)
            pending.resolve(false)
        }
        audio.stopSpeaking()
        stt.cancel()
    }

    /// Met à jour le statut du dernier tool trace.
    public func markLastToolTrace(_ status: String) {
        if let idx = toolTrace.indices.last {
            toolTrace[idx].status = status
        }
        isToolRunning = false
        currentToolName = ""
    }

    // MARK: - Notifications fin de tour

    /// Notifie la fin d'un tour SI l'app est en arrière-plan ET que le tour a duré.
    public func notifyTurnFinishedIfBackground(startedAt: Date) {
        guard Self.shouldNotifyTurnFinished(startedAt: startedAt, isActive: NSApp.isActive) else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Jarvis a terminé"
            content.body = "Ta réponse est prête."
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// NOTE : `internal`/`static` pour les tests — fonction pure.
    nonisolated static func shouldNotifyTurnFinished(startedAt: Date, isActive: Bool, now: Date = Date(), threshold: TimeInterval = 8) -> Bool {
        AnswerGuards.shouldNotifyTurnFinished(startedAt: startedAt, isActive: isActive, now: now, threshold: threshold)
    }

    // MARK: - Audit outils

    /// Journal d'audit persistant d'un appel d'outil.
    private func auditTool(conversationId: Int?, tool: String, args: String, status: String, result: String) async {
        try? await db.logToolRun(conversationId: conversationId, tool: tool, args: args, status: status, result: result)
    }

    /// Résumé compact d'arguments pour le journal.
    nonisolated static func argsSummary(_ args: [String: Any]) -> String {
        ToolCallLoop.argsSummary(args)
    }

    /// Extrait les URLs sources d'un résultat d'outil.
    nonisolated static func extractSourceURLs(from toolResult: String) -> [String] {
        ToolCallLoop.extractSourceURLs(from: toolResult)
    }

    // MARK: - Panneau audit outils (/tools)

    public var showTools = false
    public var toolRuns: [ToolRun] = []

    public func loadToolRuns() async {
        do {
            toolRuns = try await db.getRecentToolRuns()
        } catch {
            onError("Erreur chargement audit outils : \(error.localizedDescription)")
        }
    }
}