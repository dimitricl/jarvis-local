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
/// de l'actor ; ici continuation + thread global + timeout qui tue le process.
/// Un process qui pend (raccourci bloqué, dialogue modal…) ne gèle jamais le tour.
enum ProcessRunner {
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 45) async throws -> (stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, String), Error>) in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do {
                    try proc.run()
                    let deadline = Date().addingTimeInterval(timeout)
                    while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                    if proc.isRunning {
                        proc.terminate()
                        cont.resume(throwing: ToolServiceError.processTimeout(command: (executable as NSString).lastPathComponent, seconds: timeout))
                        return
                    }
                    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    cont.resume(returning: (out, err))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
