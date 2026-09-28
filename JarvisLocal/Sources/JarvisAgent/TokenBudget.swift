import Foundation
import JarvisKit

/// L1 — budget de contexte explicite, compté en TOKENS.
///
/// Estimation calibrée : ~4 caractères/token par défaut (heuristique
/// documentée comme borne), recalibrée sur `prompt_eval_count` renvoyé par
/// Ollama quand il est disponible. Jamais de troncature aveugle en caractères.
public struct TokenEstimator: Sendable {
    /// Caractères par token (4.0 par défaut, ajusté par calibration).
    public private(set) var charsPerToken: Double

    public init(charsPerToken: Double = 4.0) {
        self.charsPerToken = charsPerToken
    }

    /// Recalibre sur une mesure réelle (`prompt_eval_count` + taille
    /// caractères du prompt envoyé). Moyenne glissante prudente.
    public mutating func calibrate(promptChars: Int, promptTokens: Int) {
        guard promptChars > 0, promptTokens > 0 else { return }
        let measured = Double(promptChars) / Double(promptTokens)
        guard measured.isFinite, measured > 0.5, measured < 20 else { return }
        charsPerToken = (charsPerToken + measured) / 2.0
    }

    public func estimate(chars: Int) -> Int {
        max(1, Int((Double(chars) / charsPerToken).rounded()))
    }

    public func estimate(messages: [Message], schemas: [ToolSpec]) -> Int {
        var chars = schemas.reduce(0) { $0 + $1.approxChars }
        chars += messages.reduce(0) { $0 + $1.approxChars }
        return estimate(chars: chars)
    }
}

/// Seuil de compaction : 75 % du contexte RÉEL du serveur (lu via `/api/ps`
/// au démarrage et après chaque rechargement — pas la valeur demandée).
public enum ContextBudget {
    public static let compactionFraction: Double = 0.75

    public static func needsCompaction(estimatedTokens: Int, realContextLength: Int?) -> Bool {
        guard let real = realContextLength, real > 0 else { return false }
        return Double(estimatedTokens) >= Double(real) * compactionFraction
    }

    /// Rappel du plan : sous pression (> 60 %), le résumé des tâches
    /// ouvertes est maintenu visible en fin de contexte.
    public static func needsPlanReminder(estimatedTokens: Int, realContextLength: Int?) -> Bool {
        guard let real = realContextLength, real > 0 else { return false }
        return Double(estimatedTokens) >= Double(real) * 0.60
    }
}
