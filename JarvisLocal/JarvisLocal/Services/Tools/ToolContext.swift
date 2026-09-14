import Foundation
import EventKit

/// Dépendances partagées des sous-services d'outils.
/// Pourquoi un contexte : chaque domaine créait son propre `EKEventStore()`
/// — deux stores se marchent dessus sur les permissions. Un seul store
/// partagé, injecté depuis ToolService, mockable en tests.
struct ToolContext: Sendable {
    let eventStore: EKEventStore
    let runProcess: @Sendable (String, [String], TimeInterval) async throws -> (stdout: String, stderr: String)

    static func live(store: EKEventStore = EKEventStore()) -> ToolContext {
        ToolContext(eventStore: store, runProcess: { exe, args, timeout in
            try await ProcessRunner.run(executable: exe, arguments: args, timeout: timeout)
        })
    }
}

/// Runner Process isolé (extrait à l'identique de l'ancien ToolService.runProcess).
/// Pourquoi isolé : `waitUntilExit()` est synchrone et bloquerait l'executor
/// de l'actor ; ici continuation + terminationHandler + timeout qui tue le process.
/// Un process qui pend (raccourci bloqué, dialogue modal…) ne gèle jamais le tour.
/// P0 senior : l'ancien polling `while isRunning { Thread.sleep(0.05) }` est
/// remplacé par `terminationHandler` + `asyncAfter` (zéro busy-loop, réveil
/// uniquement à la sortie ou au timeout).
enum ProcessRunner {
    /// Plafond par flux : un process bavard (mdfind sans limite, shortcuts qui
    /// renvoie un blob) ne doit jamais matérialiser des Go de String en RAM.
    static let maxOutputBytes = 512_000

    static func run(executable: String, arguments: [String], timeout: TimeInterval = 45) async throws -> (stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, String), Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            // Garde anti-double-resume (sortie normale vs timeout).
            let lock = NSLock()
            var settled = false
            func settle(_ action: () -> Void) {
                lock.lock(); defer { lock.unlock() }
                guard !settled else { return }
                settled = true
                action()
            }
            func cappedString(_ data: Data) -> String {
                // Troncation AVANT décodage UTF-8 : borne le pic mémoire
                // (Data + String) au lieu de convertir des Go puis couper.
                let slice = data.count > maxOutputBytes ? data.prefix(maxOutputBytes) : data[...]
                var s = String(data: Data(slice), encoding: .utf8) ?? ""
                if data.count > maxOutputBytes {
                    s += "\n…[sortie tronquée : \(data.count) octets, \(maxOutputBytes) conservés]"
                }
                return s
            }
            proc.terminationHandler = { p in
                let out = cappedString((try? outPipe.fileHandleForReading.readToEnd()) ?? Data())
                let err = cappedString((try? errPipe.fileHandleForReading.readToEnd()) ?? Data())
                _ = p.terminationStatus
                settle { cont.resume(returning: (out, err)) }
            }
            do {
                try proc.run()
            } catch {
                settle { cont.resume(throwing: error) }
                return
            }
            // Timeout : tue le process puis résout en erreur timeout. On ne
            // REMPLACE PLUS la terminationHandler (race : si le process vient
            // de sortir, le nouveau handler ne fire jamais et la continuation
            // reste suspendue pour toujours) — le garde `settled` arbitre entre
            // la sortie normale et le timeout, le premier arrivé gagne.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard proc.isRunning else { return }
                proc.terminate()
                // Si terminate ne suffit pas (process ignoré), escalation.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if proc.isRunning { proc.interrupt() }
                }
                settle {
                    cont.resume(throwing: ToolServiceError.processTimeout(command: (executable as NSString).lastPathComponent, seconds: timeout))
                }
            }
        }
    }
}
