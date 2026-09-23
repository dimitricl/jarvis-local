import Foundation

/// Demande de confirmation affichée à l'utilisateur avant l'exécution d'un tool sensible.
/// Extraite à l'identique depuis AppViewModel.swift (aucun changement de comportement).
public struct ToolConfirmationRequest: Identifiable {
    public let id = UUID()
    public let toolName: String
    public let summary: String
    private let box: ResolveBox

    public init(toolName: String, summary: String, resolve: @escaping (Bool) -> Void) {
        self.toolName = toolName
        self.summary = summary
        self.box = ResolveBox(resolve)
    }

    public func resolve(_ approved: Bool) { box.resolve(approved) }

    private final class ResolveBox: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        private let inner: (Bool) -> Void
        init(_ inner: @escaping (Bool) -> Void) { self.inner = inner }
        func resolve(_ approved: Bool) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            lock.unlock()
            inner(approved)
        }
    }
}
