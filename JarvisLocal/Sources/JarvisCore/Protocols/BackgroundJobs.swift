import Foundation

/// L0 — contrat du registre de jobs vu par l'orchestration (ViewModel).
/// Implémentation : JobRegistry (JarvisServices, actor). Le ViewModel ne retient
/// qu'un `any BackgroundJobRegistry` — jamais le type concret, comme ToolExecutor.
/// `Sendable` : l'existentiel est stocké sur le ViewModel @MainActor sans friction.
public protocol BackgroundJobRegistry: Sendable {
    /// Crée un JobRecord (pending), lance le travail en tâche de fond et retourne
    /// son identifiant. `timeout` (secondes, optionnel) : passé ce délai, un travail
    /// coopératif est annulé et le job bascule en failed — jamais bloqué en running.
    /// Le `work` peut être N'IMPORTE QUELLE tâche async (pas seulement un appel LLM) :
    /// c'est ce qui rend le socle réutilisable pour les itérations futures (vision…).
    func enqueue(
        title: String,
        timeout: TimeInterval?,
        work: @escaping @Sendable () async throws -> String
    ) async -> JobID

    /// Annule la tâche associée et marque le job cancelled (si non terminal).
    /// Sans effet sur un job déjà terminé — ni crash, ni corruption.
    func cancel(_ id: JobID) async

    /// Statut courant, nil si l'id est inconnu (ou purgé de l'historique borné).
    func status(_ id: JobID) async -> JobStatus?

    /// Photo instantanée triée par création (pour amorcer l'UI avant le flux).
    func snapshot() async -> [JobRecord]

    /// Flux des republications de JobRecord (une entrée par transition).
    /// Un appel = un abonnement indépendant (broadcast, pas de vol entre abonnés).
    func updates() async -> AsyncStream<JobRecord>
}

public extension BackgroundJobRegistry {
    /// Surcharge sans timeout (cas courant) : la spec nomme enqueue(title:work:),
    /// le timeout reste configurable via la forme complète ci-dessus.
    func enqueue(
        title: String,
        work: @escaping @Sendable () async throws -> String
    ) async -> JobID {
        await enqueue(title: title, timeout: nil, work: work)
    }
}
