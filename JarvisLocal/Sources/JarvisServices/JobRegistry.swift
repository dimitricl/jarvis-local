import Foundation
import JarvisCore

/// Course timeout/contre travail : lève JobError.timeout au bout du délai.
/// Fonction libre (pas méthode d'actor) POUR UNE RAISON précise : elle s'exécute
/// HORS isolation de l'actor (appelée depuis une Task détachée). Si elle était
/// une méthode isolée, chaque job monopoliserait l'actor pendant son `work` et
/// deux jobs ne tourneraient plus vraiment en concurrence (sérialisation +
/// risque de blocage du registre : status/cancel attendraient la fin du travail).
/// Exige un `work` coopératif (Task.checkCancellation / sleep annulable /
/// withTaskCancellationHandler côté travail long) : un travail qui ignore
/// l'annulation retient sa Task jusqu'à son retour — contrat standard de
/// Swift Concurrency, pas une limitation du registre. Le record, lui, bascule
/// en failed dès le délai écoulé ; la complétion tardive est ensuite ignorée
/// par la garde terminale de l'actor.
private func raceWorkAgainstTimeout(
    _ work: @escaping @Sendable () async throws -> String,
    timeout: TimeInterval
) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            throw JobError.timeout(seconds: timeout)
        }
        do {
            // Premier fini gagne : valeur du travail OU erreur de timeout.
            // `next()` propage aussi CancellationError si l'extérieur annule.
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

/// Socle générique d'exécution de tâches de fond (itération agents).
/// Implémentation du protocol BackgroundJobRegistry (JarvisCore) : le ViewModel
/// ne retient que le protocol. Actor = exclusion mutuelle gratuite sur tout
/// l'état partagé (records, tasks, subscribers) — aucune lock manuelle, aucun
/// await sous verrou puisque l'actor ne bloque jamais : les hops d'état sont
/// synchrones et courts, le travail long tourne HORS actor (Task détachée).
public actor JobRegistry: BackgroundJobRegistry {
    public static let shared = JobRegistry()

    /// Historique borné : sans borne, chaque job (même microscopique) resterait
    /// en mémoire pour toute la session. Au-delà, on purge le terminal le plus
    /// ancien — jamais un job actif (pending/running).
    static let maxStoredRecords = 100

    private var records: [JobID: JobRecord] = [:]
    private var tasks: [JobID: Task<Void, Never>] = [:]
    /// Broadcast : un abonnement (un appel à updates()) = une continuation
    /// stockée. Contrairement au slot unique d'AudioService (un seul créateur,
    /// compteur de génération), ici N abonnés coexistent — chacun reçoit chaque
    /// transition, personne ne vole les événements d'autrui.
    private var subscribers: [UUID: AsyncStream<JobRecord>.Continuation] = [:]

    public init() {}

    // MARK: - Enqueue

    /// Crée le record (pending), publie, lance une Task DÉTACHÉE stockée pour
    /// l'annulation, retourne l'id immédiatement (jamais de travail sous isolation).
    /// Le `work` doit être coopératif côté annulation (voir raceWorkAgainstTimeout) :
    /// le registre se charge de livrer l'annulation (task.cancel()), pas de
    /// deviner comment le travail s'interrompt — d'où withTaskCancellationHandler
    /// recommandé dans les travaux longs fournis par les itérations futures.
    public func enqueue(
        title: String,
        timeout: TimeInterval? = nil,
        work: @escaping @Sendable () async throws -> String
    ) -> JobID {
        let id = UUID()
        let now = Date()
        let record = JobRecord(id: id, title: title, status: .pending, createdAt: now, updatedAt: now)
        records[id] = record
        pruneIfNeeded()
        publish(record)
        // DÉTACHÉE et pas Task{} : un Task{} créé ici hériterait de l'isolation
        // de l'actor et le `await work()` sérialiserait tous les jobs (pire :
        // cancel/status attendraient la fin du travail long). La détachée ne
        // re-hop sur l'actor que pour deux transitions brèves (running, finale).
        let task = Task.detached { [self, work] in
            await self.setStatus(id, .running)
            let result: Result<String, Error>
            do {
                let value: String
                if let timeout {
                    value = try await raceWorkAgainstTimeout(work, timeout: timeout)
                } else {
                    try Task.checkCancellation()
                    value = try await work()
                }
                // Le travail a pu être annulé sans lever (API non coopérative qui
                // retourne quand même) : on ne déclare jamais "succès" sous annulation.
                result = Task.isCancelled ? .failure(CancellationError()) : .success(value)
            } catch {
                result = .failure(error)
            }
            await self.finish(id: id, result: result)
        }
        tasks[id] = task
        return id
    }

    // MARK: - Cancel / Status / Snapshot / Updates

    /// Annule la Task stockée ET marque cancelled aussitôt si le job est encore
    /// actif — pas juste task.cancel() dans le vide : l'UI reçoit un retour
    /// immédiat même si le travail met un moment à s'interrompre. Si le job a
    /// déjà un statut terminal (fini entre-temps), no-op total : ni crash
    /// (tâche absente => optional-chaining), ni réécriture (garde terminale).
    public func cancel(_ id: JobID) {
        tasks[id]?.cancel()
        setStatus(id, .cancelled)
    }

    public func status(_ id: JobID) -> JobStatus? {
        records[id]?.status
    }

    /// Record complet (pratique pour l'UI/tests) — la spec n'exige que status(_:).
    public func record(_ id: JobID) -> JobRecord? {
        records[id]
    }

    public func snapshot() -> [JobRecord] {
        records.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Pourquoi AsyncStream plutôt que Combine : le reste du code est
    /// concurrency-first (pas de Combine dans Services), AsyncStream ne demande
    /// aucune dépendance, supporte nativement plusieurs abonnés via ce broadcast,
    /// et se consomme avec for-await sans scheduler ni thread à gérer.
    public func updates() -> AsyncStream<JobRecord> {
        let key = UUID()
        return AsyncStream { [self] continuation in
            // Ce body tourne sur l'actor (updates() est isolée) : l'insertion est
            // donc atomique avec le reste de l'état, sans lock.
            self.subscribers[key] = continuation
            continuation.onTermination = { [weak self] _ in
                // onTermination est non-isolé : hop async vers l'actor pour
                // retirer la continuation (pas de UNSAFE, pas de lock manuelle).
                Task { await self?.removeSubscriber(key) }
            }
        }
    }

    // MARK: - Privé (transitions sous isolation, toutes synchrones et brèves)

    /// Compare-and-set central : on ne transite que depuis pending/running.
    /// C'est LUI qui rend "cancel après fin" inoffensif dans les deux sens :
    /// - cancel() tardif sur job succeeded/failed/cancelled => ignoré ;
    /// - complétion tardive (timeout déjà marqué, cancel déjà marqué) => ignorée.
    /// Le gagnant est le premier à atteindre le terminal, les retardataires
    /// perdent silencieusement au lieu de corrompre le registre.
    private func setStatus(_ id: JobID, _ status: JobStatus) {
        guard let current = records[id], !current.status.isTerminal else { return }
        let updated = current.withStatus(status)
        records[id] = updated
        publish(updated)
    }

    private func finish(id: JobID, result: Result<String, Error>) {
        defer { tasks[id] = nil }
        switch result {
        case .success(let value):
            setStatus(id, .succeeded(value))
        case .failure(let error) where error is CancellationError:
            setStatus(id, .cancelled)
        case .failure(let error as JobError):
            // Timeout (ou futur cas JobError) : message stable depuis Core.
            setStatus(id, .failed(error.message))
        case .failure where Task.isCancelled:
            // Erreur quelconque mais tâche annulée entre-temps : l'annulation
            // gagne, on n'affiche pas un "échec" pour un stop volontaire.
            // (Pas de `let error` : la valeur est inutilisée ici — un binding
            // muet déclenche un warning no-usage en Release.)
            setStatus(id, .cancelled)
        case .failure(let error):
            setStatus(id, .failed(error.localizedDescription))
        }
    }

    private func publish(_ record: JobRecord) {
        for continuation in subscribers.values {
            continuation.yield(record)
        }
    }

    private func removeSubscriber(_ key: UUID) {
        subscribers[key] = nil
    }

    private func pruneIfNeeded() {
        while records.count > Self.maxStoredRecords {
            guard let oldest = records.values
                .filter({ $0.status.isTerminal })
                .min(by: { $0.updatedAt < $1.updatedAt })
            else { return } // que des actifs : on ne purge jamais un job vivant
            records[oldest.id] = nil
        }
    }
}
