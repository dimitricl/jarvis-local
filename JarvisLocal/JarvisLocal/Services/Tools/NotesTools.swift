import Foundation

/// Domaine Notes (Apple Notes via AppleScript).
/// Code déplacé à l'identique depuis ToolService.
actor NotesTools {
    func create(title: String, body: String) async throws -> String {
        let script = """
        tell application "Notes"
            set n to make new note with properties {name:"\(title.escapingForAppleScript)", body:"\(body.escapingForAppleScript)"}
            show n
        end tell
        """
        return try await AppleScriptRunner.run(script)
    }

    func edit(searchTitle: String, body: String, newTitle: String?) async throws -> String {
        var script = """
        tell application "Notes"
            set foundNote to missing value
            repeat with acc in accounts
                repeat with f in folders of acc
                    try
                        set matchingNote to first note of f whose name contains "\(searchTitle.escapingForAppleScript)"
                        set foundNote to matchingNote
                        exit repeat
                    end try
                end repeat
                if foundNote is not missing value then exit repeat
            end repeat
            if foundNote is missing value then return "Note introuvable."
        """
        if let nt = newTitle {
            script += "\nset name of foundNote to \"\(nt.escapingForAppleScript)\""
        }
        script += """
        \nset body of foundNote to "\(body.escapingForAppleScript)"
            show foundNote
            return "Note mise à jour."
        end tell
        """
        return try await AppleScriptRunner.run(script)
    }
}

/// Domaine Mémoire (faits clé/valeur en SQLite).
/// Pourquoi un actor dédié et pas un appel DB direct dans execute() :
/// l'écriture mémoire avait un `try?` silencieux qui annonçait un succès
/// mensonger — ici l'échec est explicite pour que le modèle l'avoue.
actor MemoryTools {
    func remember(key: String, value: String) async -> String {
        guard !key.isEmpty, !value.isEmpty else { return "Erreur : clé et valeur requis." }
        do {
            try await DatabaseService.shared.upsertFact(key: key, value: value)
        } catch {
            return "Échec de mémorisation (\(key)) : \(error.localizedDescription). Tu n'as RIEN enregistré : dis-le clairement et ne prétends pas le contraire."
        }
        return "Fait mémorisé : \(key) = \(value)"
    }
}
