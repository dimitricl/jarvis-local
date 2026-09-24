import Foundation
import JarvisCore

/// Coordinateur d'extraction de faits (étape 1 du découpage AppViewModel).
/// Responsabilité unique : heuristique d'extraction + confirmation + persistance.
/// Ne touche ni au LLM ni aux tools ni aux notifications — juste `db`.
/// Les closures injectées portent l'UI (confirmation sheet, annonce vocale) :
/// le coordinator reste testable sans ViewModel.
@MainActor
public final class FactsExtractionCoordinator {
    private let db: any PersistentStore
    private let requestConfirmation: (String) async -> Bool
    private let announceVoice: () async -> Void
    private let didUpdateFacts: ([Fact]) async -> Void
    private let reportError: (String) async -> Void

    public init(
        db: any PersistentStore,
        requestConfirmation: @escaping (String) async -> Bool,
        announceVoice: @escaping () async -> Void = {},
        didUpdateFacts: @escaping ([Fact]) async -> Void = { _ in },
        reportError: @escaping (String) async -> Void = { _ in }
    ) {
        self.db = db
        self.requestConfirmation = requestConfirmation
        self.announceVoice = announceVoice
        self.didUpdateFacts = didUpdateFacts
        self.reportError = reportError
    }

    // MARK: - Heuristique pure (forwarders FactExtractor, comportement identique)

    public nonisolated static func normalizeNameToken(_ token: some StringProtocol) -> String {
        FactExtractor.normalizeNameToken(token)
    }

    public nonisolated static func isExcludedNameValue(_ value: String) -> Bool {
        FactExtractor.isExcludedNameValue(value)
    }

    public nonisolated static func trimNameTrailingStoppers(_ value: String) -> String {
        FactExtractor.trimNameTrailingStoppers(value)
    }

    public func extractCandidateFacts(from text: String) -> [(key: String, value: String)] {
        FactExtractor().extract(from: text)
    }

    // MARK: - Confirmation + persistance (déplacé à l'identique depuis AppViewModel)

    public func extractAndConfirmFacts(from text: String) async {
        let candidates = extractCandidateFacts(from: text)
        guard !candidates.isEmpty else { return }
        let known = (try? await db.getAllFacts()) ?? []
        let toConfirm = candidates.filter { c in
            known.first(where: { $0.key == c.key })?.value != c.value
        }
        guard !toConfirm.isEmpty else { return }
        let summary = "Jarvis a repéré ces informations à mémoriser :\n\n" +
            toConfirm.map { "• \($0.key) = \($0.value)" }.joined(separator: "\n")
        await announceVoice()
        let approved = await requestConfirmation(summary)
        guard approved else { return }
        do {
            for c in toConfirm {
                try await db.upsertFact(key: c.key, value: c.value)
            }
            await didUpdateFacts(try await db.getAllFacts())
        } catch {
            await reportError("Mémoire : écriture impossible (\(error.localizedDescription)). L'info n'a PAS été mémorisée.")
        }
    }

    // MARK: - CRUD faits

    public func loadFacts() async -> [Fact] {
        (try? await db.getAllFacts()) ?? []
    }

    public func loadFactsReporting() async {
        // Variante qui remonte l'erreur via reportError (comportement AppViewModel).
        do {
            await didUpdateFacts(try await db.getAllFacts())
        } catch {
            await reportError("Erreur chargement faits : \(error.localizedDescription)")
        }
    }

    public func deleteFact(_ fact: Fact) async {
        do {
            try await db.deleteFact(key: fact.key)
            await didUpdateFacts(try await db.getAllFacts())
        } catch {
            await reportError("Erreur suppression fait : \(error.localizedDescription)")
        }
    }

    public func clearAllFacts() async {
        do {
            try await db.deleteAllFacts()
            await didUpdateFacts([])
        } catch {
            await reportError("Erreur effacement faits : \(error.localizedDescription)")
        }
    }
}
