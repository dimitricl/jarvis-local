import Foundation

/// L0 — contrats voix. Implémentations : AudioService / STTService (JarvisServices).
/// Le ViewModel ne retient que ces protocols — jamais les classes concrètes.

public protocol TTSEngine {
    func speak(_ text: String) async
    func enqueue(_ text: String)
    func stopSpeaking()
    var isSpeaking: Bool { get }
}

/// Référence sémantique exigée : le ViewModel pose un callback (`onPartialResult`)
/// sur une propriété `let` — seul un type référence peut satisfaire ça.
public protocol STTEngine: AnyObject {
    var onPartialResult: ((String) -> Void)? { get set }
    func transcribe() async throws -> String
    func cancel()
}

/// Erreurs STT déplacées à l'identique depuis AudioService.swift : le ViewModel
/// (JarvisUI) discrimine `STTError.cancelled` dans son catch, il doit donc voir
/// le type sans importer JarvisServices.
public enum STTError: Error, CustomStringConvertible, Equatable {
    case notAuthorized
    case cancelled
    case noSpeech
    case notAvailable
    case engineError(String)

    public var description: String {
        switch self {
        case .notAuthorized: return "Permission micro refusée"
        case .cancelled: return "Annulé"
        case .noSpeech: return "Aucune parole détectée"
        case .notAvailable: return "Reconnaissance vocale indisponible"
        case .engineError(let s): return "Erreur moteur audio : \(s)"
        }
    }
}
