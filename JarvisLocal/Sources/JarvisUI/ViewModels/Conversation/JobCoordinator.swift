import Foundation
import JarvisCore

/// Coordinateur de gestion des jobs d'arrière-plan (extraits d'AppViewModel).
/// Responsabilité unique : observation du registre, miroir UI, enqueue/cancel.
/// L'état observable reste dans AppViewModel ; ce coordinateur opère via callbacks.
@MainActor
public final class JobCoordinator {
    // MARK: - Dépendances

    private let jobsRegistry: (any BackgroundJobRegistry)?
    private let getJobs: () -> [JobRecord]
    private let onJobsChange: ([JobRecord]) -> Void

    /// Crée le coordinateur.
    init(
        jobsRegistry: (any BackgroundJobRegistry)?,
        getJobs: @escaping () -> [JobRecord],
        onJobsChange: @escaping ([JobRecord]) -> Void
    ) {
        self.jobsRegistry = jobsRegistry
        self.getJobs = getJobs
        self.onJobsChange = onJobsChange
    }

    private var jobsObservationTask: Task<Void, Never>?

    /// Borne du miroir UI : on garde les actifs + un historique récent, pas
    /// tout depuis le lancement (le registre, lui, borne à 100).
    public static let maxMirroredJobs = 50

    /// Souscrit au flux du registre et maintient `jobs` à jour. Idempotente.
    /// POURQUOI une Task stockée plutôt qu'un .task SwiftUI : l'abonnement vit
    /// aussi longtemps que le ViewModel (pas que la vue), survit aux
    /// recompositions, et se coupe proprement via stopObservingJobs().
    /// La boucle fait `for await` (suspension, JAMAIS de blocage du main thread :
    /// chaque réveil ne fait qu'un upsert synchrone) et ne duplique AUCUNE
    /// logique de concurrence — l'actor reste seul ordonnanceur, ici on miroite.
    public func startObservingJobs() {
        guard jobsObservationTask == nil, let registry = jobsRegistry else { return }
        jobsObservationTask = Task { [weak self] in
            // Photo initiale : l'UI affiche l'existant sans attendre la
            // première transition (un job fini avant l'abonnement sinon invisible).
            let initial = await registry.snapshot()
            self?.onJobsChange(Array(initial.suffix(Self.maxMirroredJobs)))

            for await record in await registry.updates() {
                guard let self else { break }
                // Vérification manuelle d'annulation pour ne pas appliquer
                // de mise à jour après stopObservingJobs() (fuite d'observation).
                if Task.isCancelled { break }
                self.applyJobUpdate(record)
            }
        }
    }

    /// Arrête l'observation. Idempotente.
    public func stopObservingJobs() {
        jobsObservationTask?.cancel()
        jobsObservationTask = nil
    }

    /// Applique une mise à jour job (upsert + tri + troncature).
    private func applyJobUpdate(_ record: JobRecord) {
        var currentJobs = getJobs()
        if let idx = currentJobs.firstIndex(where: { $0.id == record.id }) {
            currentJobs[idx] = record
        } else {
            currentJobs.append(record)
        }
        currentJobs.sort { $0.createdAt < $1.createdAt }
        if currentJobs.count > Self.maxMirroredJobs {
            currentJobs = Array(currentJobs.suffix(Self.maxMirroredJobs))
        }
        onJobsChange(currentJobs)
    }

    /// Enqueue un job dans le registre. Retourne l'ID.
    public func enqueueJob(
        title: String,
        timeout: TimeInterval? = nil,
        work: @escaping @Sendable () async throws -> String
    ) async -> JobID? {
        guard let registry = jobsRegistry else { return nil }
        return await registry.enqueue(title: title, timeout: timeout, work: work)
    }

    /// Demande l'annulation d'un job.
    public func cancelJob(_ id: JobID) async {
        guard let registry = jobsRegistry else { return }
        await registry.cancel(id)
    }
}
