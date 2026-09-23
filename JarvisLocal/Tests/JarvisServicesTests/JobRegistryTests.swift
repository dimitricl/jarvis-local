@testable import JarvisServices
import JarvisCore
import XCTest

/// Socle jobs d'arrière-plan (itération agents) : ce fichier ferme les trous
/// de concurrence du registre, pas sa simple logique métier.
/// - Deux jobs concurrents partagent un actor : prouver qu'ils tournent VRAIMENT
///   en parallèle (travail hors isolation) au lieu de se sérialiser, et que leurs
///   statuts ne se mélangent pas.
/// - Annuler un job déjà fini (course cancel/finish) ne doit ni crasher ni
///   réécrire le statut terminal — le gagnant est le premier arrivé.
/// - Un timeout doit faire basculer en failed VITE (pas de running éternel),
///   ce qui n'est garanti que si le travail coopère avec l'annulation.
/// Chaque test = un scénario nommé (testXxxYyy), registre frais par test
/// (jamais le shared : isolation entre tests).
final class JobRegistryTests: XCTestCase {
    /// Attend un statut terminal, avec garde-fou : un job qui resterait en
    /// running indéfiniment fait échouer le test au lieu de le bloquer.
    private func awaitTerminalStatus(
        _ registry: JobRegistry,
        id: JobID,
        timeout: TimeInterval = 5
    ) async -> JobStatus? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let s = await registry.status(id), s.isTerminal { return s }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await registry.status(id)
    }

    func testEnqueueDeliversWorkResultAsSucceeded() async {
        let registry = JobRegistry()
        let id = await registry.enqueue(title: "echo") { "bonjour" }
        let status = await awaitTerminalStatus(registry, id: id)
        XCTAssertEqual(status, .succeeded("bonjour"))
    }

    func testEnqueueThrowingWorkMapsToFailed() async {
        struct Boom: Error {}
        let registry = JobRegistry()
        let id = await registry.enqueue(title: "boom") { throw Boom() }
        let status = await awaitTerminalStatus(registry, id: id)
        guard case .failed(let message) = status else {
            return XCTFail("attendu failed, obtenu \(String(describing: status))")
        }
        XCTAssertFalse(message.isEmpty, "un échec sans message est inexploitable pour l'UI")
        // Le registre reste utilisable après un échec (pas d'état vérolé).
        let id2 = await registry.enqueue(title: "après-échec") { "ok" }
        let status2 = await awaitTerminalStatus(registry, id: id2)
        XCTAssertEqual(status2, .succeeded("ok"))
    }

    func testCancelRunningJobMarksCancelled() async {
        let registry = JobRegistry()
        let id = await registry.enqueue(title: "long") {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return "trop tard"
        }
        // Laisse le job démarrer (running) avant d'annuler.
        try? await Task.sleep(nanoseconds: 100_000_000)
        await registry.cancel(id)
        let status = await awaitTerminalStatus(registry, id: id)
        XCTAssertEqual(status, .cancelled, "un stop volontaire n'est pas un échec")
    }

    func testCancelFinishedJobIsHarmlessNoop() async {
        let registry = JobRegistry()
        let id = await registry.enqueue(title: "instantané") { "vite" }
        let first = await awaitTerminalStatus(registry, id: id)
        XCTAssertEqual(first, .succeeded("vite"))
        // Course cancel/finish : le cancel tardif ne doit ni crasher ni écraser.
        await registry.cancel(id)
        await registry.cancel(id)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let afterCancel = await registry.status(id)
        XCTAssertEqual(afterCancel, .succeeded("vite"))
    }

    func testLateCompletionAfterCancelDoesNotOverwriteCancelled() async {
        let registry = JobRegistry()
        // Travail qui ignore l'annulation et retourne quand même : le registre
        // doit garder cancelled (le premier terminal gagne), pas succeeded.
        let id = await registry.enqueue(title: "têtu") {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return "j'ai fini quand même"
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await registry.cancel(id)
        // Laisse le travail "têtu" se terminer après le cancel.
        try? await Task.sleep(nanoseconds: 600_000_000)
        let final = await registry.status(id)
        XCTAssertEqual(final, .cancelled)
    }

    func testTimeoutFailsCooperativeWorkQuickly() async {
        let registry = JobRegistry()
        let startedAt = Date()
        let id = await registry.enqueue(title: "bourbier", timeout: 0.3) {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return "jamais"
        }
        let status = await awaitTerminalStatus(registry, id: id)
        let elapsed = Date().timeIntervalSince(startedAt)
        guard case .failed(let message) = status else {
            return XCTFail("attendu failed(timeout), obtenu \(String(describing: status))")
        }
        XCTAssertTrue(message.contains("pas répondu"), "message inattendu : \(message)")
        XCTAssertLessThan(elapsed, 5, "le timeout doit basculer vite, pas attendre le travail (\(elapsed)s)")
    }

    func testConcurrentJobsKeepIndependentStatuses() async {
        let registry = JobRegistry()
        // 10 jobs, durées mélangées : s'ils se sérialisaient sur l'actor, le
        // total vaudrait la somme (~5s) ; en parallèle, ~le plus long seul.
        let startedAt = Date()
        var ids: [JobID] = []
        for i in 0..<10 {
            let delay = UInt64((i % 3 + 1)) * 200_000_000
            let id = await registry.enqueue(title: "job-\(i)") {
                try await Task.sleep(nanoseconds: delay)
                return "résultat-\(i)"
            }
            ids.append(id)
        }
        for (i, id) in ids.enumerated() {
            let status = await awaitTerminalStatus(registry, id: id, timeout: 10)
            XCTAssertEqual(status, .succeeded("résultat-\(i)"), "le statut du job \(i) a été mélangé")
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertLessThan(elapsed, 4, "10 jobs de ≤0.6s en \(elapsed)s : ils se sont sérialisés sur l'actor")
    }

    func testUpdatesStreamPublishesTransitionsForSubscriber() async {
        let registry = JobRegistry()
        let stream = await registry.updates()
        let collector = Task {
            var seen: [JobRecord] = []
            for await record in stream {
                seen.append(record)
                if record.status.isTerminal { break }
            }
            return seen
        }
        let id = await registry.enqueue(title: "observé") { "vu" }
        let seen = await collector.value
        let mine = seen.filter { $0.id == id }.map(\.status)
        XCTAssertTrue(mine.contains(.running), "la transition running n'a pas été publiée")
        XCTAssertEqual(mine.last, .succeeded("vu"))
    }

    func testStatusOfUnknownIdIsNil() async {
        let registry = JobRegistry()
        let unknown = await registry.status(UUID())
        XCTAssertNil(unknown, "un id inconnu doit répondre nil, pas crasher")
        await registry.cancel(UUID()) // no-op exigé, aucun throw/crash possible
    }
}
