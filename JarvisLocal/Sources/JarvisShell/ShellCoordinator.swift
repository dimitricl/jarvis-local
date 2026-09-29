import AppKit
import Combine
import Foundation
import Network
import os
import SwiftUI
import JarvisKit
import JarvisAgent
import JarvisProviders
import JarvisServices

/// L3 — coordinateur du shell : hotkey, HUD, voix, monitor, agent.
///
/// `@MainActor` : tout l'état observable vit ici (HUD, étapes, saisie).
/// Le run agent tourne en fond ; chaque `AgentEvent` passe par `HUDReduce`
/// (pur). Un seul run à la fois. L'app ne quitte JAMAIS à la fermeture
/// d'une fenêtre (plus de `applicationShouldTerminateAfterLastWindowClosed`).
/// `@unchecked Sendable` justifié : classe finale `@MainActor`, tout état
/// muté exclusivement sur le MainActor ; les callbacks `@Sendable` (hotkey,
/// voix) y retournent via `Task { @MainActor … }`. Aucun accès concurrent.
@MainActor
public final class ShellCoordinator: @unchecked Sendable, ObservableObject {
    @Published public var hudState: HUDState = .idle
    @Published public var steps: [String] = []
    @Published public var input: String = ""
    @Published public var settings: ShellSettings

    private var host: AgentHost?
    private var panel: HUDPanelController?
    private var hotkey: HotkeyManager?
    private var voice: VoiceDriver?
    private var monitorTask: Task<Void, Never>?
    private var dictationTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var runActive = false
    private var pendingConfirm: (callId: String, tool: String)?
    private var lastHostKey = ""
    private let log = Logger(subsystem: "com.dimitriclaverie.JarvisLocal", category: "shell")

    public init(settings: ShellSettings = ShellSettings()) {
        self.settings = settings
    }

    // MARK: - Démarrage

    public func boot() {
        rebuildHost()
        ensurePanel()
        let hotkey = HotkeyManager(
            config: HotkeyConfig(keyCode: settings.hotkeyKeyCode),
            onGesture: { [weak self] gesture in Task { @MainActor in await self?.handleGesture(gesture) } },
            onEscape: { [weak self] in Task { @MainActor in await self?.handleGlobalEscape() } })
        self.hotkey = hotkey
        hotkey.start()
        let voice = VoiceDriver(
            onEvent: { [weak self] event in Task { @MainActor in self?.handleVoice(event) } })
        self.voice = voice
        startMonitor()
        startPathMonitor()
        Task { await self.probeAndWarmup() }
    }

    public func rebuildHost() {
        let key = "\(settings.ollamaURL)|\(settings.model)|\(settings.numCtx)"
        guard key != lastHostKey else { return }
        lastHostKey = key
        do {
            host = try AgentHost(runtime: AgentHost.Runtime(settings: settings))
        } catch {
            host = nil
            // État DISTINCT du réseau : le polling continue en fond et le
            // HUD affichera le vrai état réseau dès la prochaine sonde.
            log.error("AgentHost init failed: \(String(describing: error), privacy: .public)")
            applyAction(.connection(.agentError(detail: String(describing: error))))
        }
    }

    public func shutdown() async {
        monitorTask?.cancel()
        pathMonitor?.cancel()
        hotkey?.stop()
        await voice?.stopSpeaking()
        await voice?.cancelDictation()
        await host?.cancel()
    }

    // MARK: - HUD

    public func showHUD() {
        ensurePanel()
        hudState = .transcribing(text: "")
        let hasPanel = panel != nil
        log.info("showHUD: panel=\(hasPanel ? "present" : "nil", privacy: .public)")
        refreshPanel()
        panel?.showForInput()
    }

    /// Filet : si une instance non `boot()`ée reçoit un ordre UI (cf.
    /// `JarvisLocalApp.init`), on (re)crée le panneau au lieu de rester muet.
    private func ensurePanel() {
        if panel == nil {
            let created = HUDPanelController()
            created.onConfirmKey = { [weak self] allowed in self?.answerConfirm(allowed: allowed, always: false) }
            created.onEscapeKey = { [weak self] in self?.interrupt() }
            created.onSubmitKey = { [weak self] in self?.submitInput() }
            panel = created
        }
    }

    internal var panelExists: Bool { panel != nil }

    private func applyAction(_ action: HUDAction) {
        hudState = HUDReduce.reduce(state: hudState, action: action, runActive: runActive)
        let desc = String(describing: hudState)
        let actDesc = String(describing: action)
        let visible = hudState.isVisible
        log.debug("applyAction \(actDesc, privacy: .public) -> \(desc, privacy: .public) visible=\(visible)")
        if hudState.isVisible {
            refreshPanel()
            panel?.show()
        } else {
            panel?.hide()
        }
    }

    private func refreshPanel() {
        guard let panel else { return }
        let inputBinding = Binding(get: { self.input }, set: { self.input = $0 })
        panel.setContent(HUDView(
            state: hudState,
            steps: steps,
            input: inputBinding,
            onConfirm: { [weak self] allowed, always in self?.answerConfirm(allowed: allowed, always: always) },
            onInterrupt: { [weak self] in self?.interrupt() },
            onSubmit: { [weak self] text in self?.runAgent(prompt: text) },
            onRetry: { [weak self] in Task { await self?.probeAndWarmup(force: true) } }))
    }

    // MARK: - Gestes hotkey

    private func handleGesture(_ gesture: HotkeyGesture) async {
        switch gesture {
        case .tap:
            if runActive {
                interrupt()
            } else if hudState.isVisible {
                applyAction(.dismiss)
            } else {
                // Tap = afficher le HUD en saisie (pas de dictée).
                hudState = .transcribing(text: "")
                refreshPanel()
                panel?.showForInput()
            }
        case .holdBegan:
            if await voice?.isSpeaking == true {
                // Barge-in au hotkey : coupe parole + run.
                interrupt()
                return
            }
            if runActive {
                interrupt()
                return
            }
            applyAction(.showListening)
            if await voice?.startDictation() == true {
                dictationTask = Task { await voice?.dictate() }
            }
        case .holdEnded:
            dictationTask?.cancel()
            await voice?.stopAndSend()
        }
    }

    private func handleGlobalEscape() async {
        if runActive {
            interrupt()
        } else if hudState.isVisible {
            applyAction(.dismiss)
        }
    }

    // MARK: - Voix

    private func handleVoice(_ event: VoiceEvent) {
        switch event {
        case .partial(let text):
            applyAction(.showTranscript(text))
        case .finalInput(let text):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else {
                applyAction(.dismiss)
                return
            }
            runAgent(prompt: clean)
        case .cancelled:
            applyAction(.dismiss)
        case .sttError(let message):
            steps.append("micro : \(message)")
            hudState = .done(summary: "Micro : \(message)")
            refreshPanel()
        }
    }

    // MARK: - Runs agent

    func runAgent(prompt: String) {
        guard let host else {
            applyAction(.connection(.agentError(detail: "agent non initialisé")))
            return
        }
        runActive = true
        steps = []
        hudState = .thinking
        refreshPanel()
        panel?.show()
        Task {
            let stream = await host.run(prompt: prompt)
            var finalText = ""
            for await event in stream {
                if case .toolStarted(_, let name, let preview) = event {
                    steps.append("⚙ \(name) \(preview.prefix(60))")
                }
                if case .permissionRequested(let callId, let tool, _, let decision) = event,
                   decision == .ask {
                    pendingConfirm = (callId: callId, tool: tool)
                    panel?.onConfirmKey = { [weak self] allowed in
                        self?.answerConfirm(allowed: allowed, always: false)
                    }
                }
                if case .done(let text, _, _) = event { finalText = text }
                applyAction(.agentEvent(event))
                refreshPanel()
            }
            runActive = false
            pendingConfirm = nil
            if settings.ttsEnabled, !finalText.isEmpty {
                hudState = .speaking(text: String(finalText.prefix(120)))
                refreshPanel()
                await voice?.speak(finalText, enabled: true)
            }
            scheduleAutoHide()
        }
    }

    func answerConfirm(allowed: Bool, always: Bool) {
        guard let pending = pendingConfirm else { return }
        pendingConfirm = nil
        panel?.onConfirmKey = nil
        Task {
            await host?.answerConfirmation(
                callId: pending.callId, tool: pending.tool, allowed: allowed, always: always)
        }
        hudState = .thinking
        refreshPanel()
    }

    func interrupt() {
        runActive = false
        pendingConfirm = nil
        Task { @MainActor [weak self] in
            await self?.voice?.stopSpeaking()
            await self?.voice?.cancelDictation()
            await self?.host?.cancel()
        }
        applyAction(.interrupted)
    }

    func submitInput() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        runAgent(prompt: text)
    }

    private func scheduleAutoHide() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !runActive, isDoneState {
                applyAction(.dismiss)
            }
        }
    }

    private var isDoneState: Bool {
        if case .done = hudState { return true }
        return false
    }

    // MARK: - Monitor + warmup

    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task {
            while !Task.isCancelled {
                await probeTick()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { await self?.probeAndWarmup() }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func probeTick() async {
        guard let base = try? OllamaHostPolicy.validateBaseURL(settings.ollamaURL) else { return }
        let request = ConnectionProbeRequest(baseURL: base, model: settings.model)
        let probe = await request.run()
        let state = ConnectionMonitor.classify(probe: probe, host: base.host ?? "?")
        guard !runActive else { return }
        if case .online = state {
            // Retour en ligne : ne masquer que nos propres états réseau/agent.
            // `.unavailable` (échec d'init) est écrasé par la vérité réseau :
            // le polling est découplé de l'existence d'un AgentHost valide.
            if isUnreachableState || isLoadingState || isUnavailableState {
                applyAction(.dismiss)
            }
        } else if isConnectionManagedState {
            // Pépin réseau : ne jamais arracher la saisie / le run / etc.
            applyAction(.connection(state))
        }
    }

    private var isUnreachableState: Bool {
        if case .unreachable = hudState { return true }
        return false
    }

    private var isLoadingState: Bool {
        if case .loading = hudState { return true }
        return false
    }

    private var isUnavailableState: Bool {
        if case .unavailable = hudState { return true }
        return false
    }

    /// États que la sonde auto est autorisée à piloter. Tout le reste
    /// (saisie, écoute, run, confirmation…) appartient à l'utilisateur :
    /// une sonde qui rend ne doit jamais le lui arracher (le HUD
    /// s'affichait puis disparaissait aussitôt — constaté en réel).
    private var isConnectionManagedState: Bool {
        switch hudState {
        case .idle, .unreachable, .loading, .unavailable: return true
        default: return false
        }
    }

    func probeAndWarmup(force: Bool = false) async {
        guard let base = try? OllamaHostPolicy.validateBaseURL(settings.ollamaURL) else { return }
        let request = ConnectionProbeRequest(baseURL: base, model: settings.model)
        let probe = await request.run()
        let state = ConnectionMonitor.classify(probe: probe, host: base.host ?? "?")
        // `force` = bouton « Réessayer » explicite : l'utilisateur demande
        // la vérité réseau même s'il est en saisie. Sinon, ne piloter que
        // les états gérés par la sonde (jamais arracher la saisie).
        if !runActive, force || isConnectionManagedState { applyAction(.connection(state)) }
        if ConnectionMonitor.needsWarmup(probe: probe) {
            if !runActive, force || isConnectionManagedState {
                hudState = .loading(elapsed: 0)
                refreshPanel()
                panel?.show()
            }
            _ = await AgentHost.warmupIfNeeded(
                baseURL: settings.ollamaURL, model: settings.model, numCtx: settings.numCtx)
            if !runActive, force || isConnectionManagedState {
                let probe2 = await request.run()
                let state2 = ConnectionMonitor.classify(probe: probe2, host: base.host ?? "?")
                applyAction(.connection(state2))
            }
        }
    }
}
