import Foundation

/// L0 — socle "jobs" d'arrière-plan (itération agents).
/// Types purs, immuables, Foundation only : aucun I/O, aucune concurrence ici.
/// Le registre mutable vit dans JarvisServices (actor JobRegistry) ; l'UI ne
/// voit que ces valeurs. Un JobRecord ne se mute jamais en place : chaque
/// transition de statut republie un record modifié (withStatus).
public typealias JobID = UUID

/// Statut d'un job. `failed` porte un message texte (pas un `Error`) :
/// un Error n'est ni Equatable ni forcément Sendable, et le record doit rester
/// une valeur pure comparable pour les tests et le diffing UI.
public enum JobStatus: Sendable, Equatable {
    case pending
    case running
    case succeeded(String)
    case failed(String)
    case cancelled

    /// Un statut terminal ne doit plus jamais être écrasé (garde anti-race :
    /// un cancel tardif ou une complétion en retard ne réécrit pas un job fini).
    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        case .pending, .running:
            return false
        }
    }

    /// Libellé français pour l'affichage minimal (le style visuel viendra plus tard).
    public var displayLabel: String {
        switch self {
        case .pending:
            return "En attente"
        case .running:
            return "En cours"
        case .succeeded:
            return "Terminé"
        case .failed:
            return "Échoué"
        case .cancelled:
            return "Annulé"
        }
    }
}

/// Enregistrement immuable d'un job : identité + titre pour l'UI + statut +
/// horodatage. Toute transition passe par withStatus (nouvelle valeur, dates
/// mises à jour) — jamais de mutation directe du record stocké.
public struct JobRecord: Sendable, Identifiable, Equatable {
    public let id: JobID
    public let title: String
    public let status: JobStatus
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: JobID, title: String, status: JobStatus, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func withStatus(_ status: JobStatus, at date: Date = Date()) -> JobRecord {
        JobRecord(id: id, title: title, status: status, createdAt: createdAt, updatedAt: date)
    }
}

/// Erreurs propres au socle jobs. Le timeout est matérialisé ici (Core) pour
/// que le message d'échec soit stable et testable sans dépendre de Services.
public enum JobError: Error, Sendable, Equatable {
    case timeout(seconds: TimeInterval)

    public var message: String {
        switch self {
        case .timeout(let seconds):
            return "Le job n'a pas répondu après \(Int(seconds))s et a été interrompu."
        }
    }
}
