import XCTest

/// CI headless (GitHub Actions) : aucun humain pour cliquer les prompts TCC
/// (Contacts, Calendriers, Rappels, micro/reconnaissance vocale, capture d'écran).
/// Un `requestAccess` sans session Aqua ne répond jamais → le test PEND
/// indéfiniment au lieu d'échouer (constaté : job Build & Test bloqué > 50 min).
/// Les tests concernés s'auto-skippent quand `CI=true` (toujours défini par
/// GitHub Actions) via `try skipIfCIHeadless(...)` en première ligne.
/// En local (permissions déjà accordées), rien ne change.
extension XCTestCase {
    func skipIfCIHeadless(_ reason: String) throws {
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("CI headless (pas de TCC) : \(reason)")
        }
    }
}
