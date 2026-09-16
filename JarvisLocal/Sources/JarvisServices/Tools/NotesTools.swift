import Foundation
import JarvisCore

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

    /// Recherche des notes par mot-clé (titre ou contenu). Retourne des couples
    /// (titre, id) : l'étape suivante (read/edit) exige un id issu de CE résultat,
    /// jamais un titre approximatif deviné.
    /// Template figé : seule `query` est interpolée (échappée) — jamais de code LLM.
    func search(query: String) async throws -> [(title: String, id: String)] {
        // Délimiteurs improbables pour parser la sortie sans ambiguïté.
        let script = """
        tell application "Notes"
            set outLines to {}
            repeat with acc in accounts
                repeat with f in folders of acc
                    repeat with n in notes of f
                        try
                            set nName to name of n
                            set nBody to body of n
                            if nName contains "\(query.escapingForAppleScript)" or nBody contains "\(query.escapingForAppleScript)" then
                                set nId to id of n
                                set end of outLines to (nId & "|||" & nName)
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            set AppleScript's text item delimiters to "\\n"
            return outLines as string
        end tell
        """
        let raw = try await AppleScriptRunner.run(script)
        let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // AppleScriptRunner renvoie "Exécuté avec succès." quand le script ne retourne
        // rien (zéro match) — pas un résultat à parser.
        if lines == ["Exécuté avec succès."] { return [] }
        return lines.compactMap { line -> (title: String, id: String)? in
            let parts = line.components(separatedBy: "|||")
            guard parts.count >= 2 else { return nil }
            return (title: parts[1], id: parts[0])
        }
    }

    /// Lit le contenu complet d'une note à partir de son identifiant (obtenu via search).
    /// Template figé : seul `id` est interpolé (échappé) — jamais de code LLM.
    func read(id: String) async throws -> String {
        let script = """
        tell application "Notes"
            repeat with acc in accounts
                repeat with f in folders of acc
                    repeat with n in notes of f
                        try
                            if id of n is "\(id.escapingForAppleScript)" then
                                return body of n
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "Note introuvable."
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
