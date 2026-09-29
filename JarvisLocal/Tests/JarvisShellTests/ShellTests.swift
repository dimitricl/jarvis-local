import XCTest
@testable import JarvisShell
@testable import JarvisKit
@testable import JarvisAgent

final class HUDStateTests: XCTestCase {
    func testPillIdleInvisible() {
        XCTAssertFalse(HUDState.idle.isVisible)
        XCTAssertEqual(HUDState.idle.pill, "")
    }

    func testReduceAgentEvents() {
        XCTAssertEqual(
            HUDReduce.reduce(state: .idle, action: .agentEvent(.thinking("hmm")), runActive: true),
            .thinking)
        XCTAssertEqual(
            HUDReduce.reduce(
                state: .thinking,
                action: .agentEvent(.toolStarted(callId: "c", name: "read_file", argumentsPreview: "a.txt")),
                runActive: true),
            .acting(tool: "read_file", target: "a.txt"))
        XCTAssertEqual(
            HUDReduce.reduce(
                state: .acting(tool: "x", target: ""),
                action: .agentEvent(.permissionRequested(callId: "c", name: "bash", reason: "shell", decision: .ask)),
                runActive: true),
            .confirming(tool: "bash", reason: "shell", callId: "c"))
        // Deny ne demande rien : retour réflexion.
        XCTAssertEqual(
            HUDReduce.reduce(
                state: .acting(tool: "x", target: ""),
                action: .agentEvent(.permissionRequested(callId: "c", name: "bash", reason: "rm", decision: .deny)),
                runActive: true),
            .thinking)
        XCTAssertEqual(
            HUDReduce.reduce(
                state: .thinking,
                action: .agentEvent(.done(finalText: "fini", turnsUsed: 2, usage: TokenUsage(promptTokens: 10, calibrated: true))),
                runActive: true),
            .done(summary: "fini"))
        XCTAssertEqual(
            HUDReduce.reduce(state: .thinking, action: .agentEvent(.failed(.timeout)), runActive: true),
            .idle)
    }

    func testConnectionNeMasquePasUnRun() {
        let acting = HUDState.acting(tool: "bash", target: "ls")
        XCTAssertEqual(
            HUDReduce.reduce(state: acting, action: .connection(.unreachable(host: "h")), runActive: true),
            acting)
        XCTAssertEqual(
            HUDReduce.reduce(state: acting, action: .connection(.unreachable(host: "h")), runActive: false),
            .unreachable(host: "h"))
    }

    func testInterruptEtDismiss() {
        XCTAssertEqual(HUDReduce.reduce(state: .acting(tool: "x", target: ""), action: .interrupted, runActive: true), .idle)
        XCTAssertEqual(HUDReduce.reduce(state: .done(summary: "x"), action: .dismiss, runActive: false), .idle)
    }

    func testPillsExplicites() {
        XCTAssertTrue(HUDState.unreachable(host: "h").pill.contains("injoignable"))
        XCTAssertTrue(HUDState.loading(elapsed: 7).pill.contains("7"))
        XCTAssertTrue(HUDState.confirming(tool: "bash", reason: "r", callId: "c").pill.contains("bash"))
    }
}

final class ConnectionMonitorTests: XCTestCase {
    func testClassify() {
        XCTAssertEqual(
            ConnectionMonitor.classify(probe: ConnectionProbe(reachable: false), host: "h"),
            .unreachable(host: "h"))
        XCTAssertEqual(
            ConnectionMonitor.classify(
                probe: ConnectionProbe(reachable: true, rttMs: 12, modelResident: false), host: "h"),
            .loadingModel(elapsed: 0))
        XCTAssertEqual(
            ConnectionMonitor.classify(
                probe: ConnectionProbe(reachable: true, rttMs: 12, modelResident: true), host: "h"),
            .online(rttMs: 12, modelResident: true))
    }

    func testWarmupSeulementSiNonResident() {
        XCTAssertTrue(ConnectionMonitor.needsWarmup(probe: ConnectionProbe(reachable: true, modelResident: false)))
        XCTAssertFalse(ConnectionMonitor.needsWarmup(probe: ConnectionProbe(reachable: true, modelResident: true)))
        XCTAssertFalse(ConnectionMonitor.needsWarmup(probe: ConnectionProbe(reachable: false)))
    }
}

final class TapHoldTests: XCTestCase {
    func testTapCourt() {
        let (down, g1) = TapHoldDetector.keyDown(phase: .idle)
        XCTAssertEqual(g1, .holdBegan)
        let (up, g2) = TapHoldDetector.keyUp(phase: down, now: Date(), threshold: 0.4)
        XCTAssertEqual(up, .idle)
        // keyUp immédiat après keyDown : durée ~0 < seuil → tap.
        XCTAssertEqual(g2, .tap)
    }

    func testHoldLong() {
        let (down, _) = TapHoldDetector.keyDown(phase: .idle)
        if case .down(let since) = down {
            let later = since.addingTimeInterval(2)
            let (up, g2) = TapHoldDetector.keyUp(phase: down, now: later, threshold: 0.4)
            XCTAssertEqual(up, .idle)
            XCTAssertEqual(g2, .holdEnded(duration: 2))
        } else {
            XCTFail("attendu down")
        }
    }

    func testKeyUpSansDownIgnore() {
        let (phase, gesture) = TapHoldDetector.keyUp(phase: .idle, threshold: 0.4)
        XCTAssertEqual(phase, .idle)
        XCTAssertNil(gesture)
    }
}

final class ShellSettingsTests: XCTestCase {
    func testIsRemote() {
        var local = ShellSettings()
        local.ollamaURL = "http://localhost:11434"
        XCTAssertFalse(local.isRemote)
        var loop = ShellSettings()
        loop.ollamaURL = "http://127.0.0.1:11434"
        XCTAssertFalse(loop.isRemote)
        var remote = ShellSettings()
        remote.ollamaURL = "http://100.87.1.2:11434"
        XCTAssertTrue(remote.isRemote)
        var broken = ShellSettings()
        broken.ollamaURL = "n'importe quoi"
        XCTAssertTrue(broken.isRemote)
    }

    func testHotkeyNames() {
        XCTAssertEqual(HotkeyNames.name(for: 105), "F13")
        XCTAssertEqual(HotkeyNames.name(for: 53), "Échap")
    }
}

final class TranscriptListTests: XCTestCase {
    func testListIDsOrdonnes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-shell-list-\(UUID().uuidString)", isDirectory: true)
        let store = FileTranscriptStore(directory: dir)
        var first = Transcript(model: "m", messages: [Message(role: .user, content: "premier")])
        try await store.save(first)
        try await Task.sleep(nanoseconds: 10_000_000)
        let second = Transcript(model: "m", messages: [Message(role: .user, content: "second")])
        try await store.save(second)
        let ids = try await store.listIDs()
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, second.id)
        _ = first
    }

    func testHistoryLoadingResume() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-shell-hist-\(UUID().uuidString)", isDirectory: true)
        let store = FileTranscriptStore(directory: dir)
        let transcript = Transcript(model: "m", messages: [Message(role: .user, content: "bonjour monde")])
        try await store.save(transcript)
        let list = await HistoryLoading.list(store: store)
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(list[0].preview.contains("bonjour"))
    }
}

final class HUDFocusPolicyTests: XCTestCase {
    func testInputRequiresRegularIdleRestoresAccessory() {
        XCTAssertEqual(HUDFocusPolicy.input, .regular)
        XCTAssertEqual(HUDFocusPolicy.idle, .accessory)
        XCTAssertNotEqual(HUDFocusPolicy.input, HUDFocusPolicy.idle)
    }
}
