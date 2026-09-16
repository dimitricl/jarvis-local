import Foundation

/// Domaine Fichiers : lecture sandboxée (list_directory / read_file).
/// Pourquoi un actor dédié : la résolution canonique + le garde fail-closed
/// sont la même classe de risque que URLSafety.isBlocked pour read_url —
///
/// - Seuls les chemins résolus (symlinks + ".." + "~" normalisés) SOUS
///   ~/Documents, ~/Desktop ou ~/Downloads sont acceptés.
/// - Toute résolution qui sort de ces racines (symlink, "..", chemin absolu
///   ailleurs, racine inexistante) = refus explicite, fail-closed.
/// - Lecture plafonnée à maxFileBytes (même pattern que WebTools.maxPageBytes,
///   via FileHandle borné — jamais de Data(contentsOf:) sur un fichier arbitraire).
/// - Fichier non décodable en UTF-8 = refus explicite (pas de mojibake au LLM).
actor FileTools {
    /// Plafond de lecture : même pattern que WebTools.maxPageBytes.
    /// NOTE : `internal`/`static` pour les tests.
    nonisolated static let maxFileBytes = 200_000

    /// Racines autorisées, résolues (symlinks) une fois pour comparer avec
    /// des chemins eux-mêmes résolus. `internal` pour les tests.
    nonisolated static func allowedRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        ["Documents", "Desktop", "Downloads"].map { home.appendingPathComponent($0).resolvingSymlinksInPath().standardized }
    }

    /// Résolution canonique : "~" étendu, relatif ancré à $HOME, symlinks
    /// résolus, ".." normalisés. Retourne nil si le chemin n'existe pas
    /// (fail-closed : on ne devine jamais, même pour lister).
    /// NOTE : `internal`/`static` pour les tests.
    nonisolated static func canonical(_ rawPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else {
            url = home.appendingPathComponent(expanded)
        }
        // resolvingSymlinksInPath exige l'existence : inexistant = nil = refus.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        return url.resolvingSymlinksInPath().standardized
    }

    /// Garde fail-closed, miroir de URLSafety.isBlocked : true = REFUSÉ.
    /// NOTE : `internal`/`static` pour les tests.
    nonisolated static func isBlocked(_ canonical: URL, roots: [URL]) -> Bool {
        let path = canonical.path
        return !roots.contains { root in
            path == root.path || path.hasPrefix(root.path + "/")
        }
    }

    func listDirectory(path: String) async -> String {
        let roots = Self.allowedRoots()
        guard let canon = Self.canonical(path) else {
            return "Chemin refusé : « \(path) » n'existe pas ou ne peut pas être résolu. Seuls ~/Documents, ~/Desktop et ~/Downloads sont accessibles — liste d'abord l'un de ces dossiers."
        }
        if Self.isBlocked(canon, roots: roots) {
            return "Chemin refusé : « \(path) » est hors sandbox (~/Documents, ~/Desktop, ~/Downloads uniquement)."
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canon.path, isDirectory: &isDir), isDir.boolValue else {
            return "Chemin refusé : « \(canon.path) » n'est pas un dossier."
        }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: canon.path) else {
            return "Impossible de lister « \(canon.path) »."
        }
        if items.isEmpty { return "Dossier vide : \(canon.path)" }
        let sorted = items.sorted().prefix(100)
        return sorted.map { canon.appendingPathComponent($0).path }.joined(separator: "\n")
    }

    func readFile(path: String) async -> String {
        let roots = Self.allowedRoots()
        guard let canon = Self.canonical(path) else {
            return "Chemin refusé : « \(path) » n'existe pas ou ne peut pas être résolu. Seuls ~/Documents, ~/Desktop et ~/Downloads sont accessibles."
        }
        if Self.isBlocked(canon, roots: roots) {
            return "Chemin refusé : « \(path) » est hors sandbox (~/Documents, ~/Desktop, ~/Downloads uniquement)."
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canon.path, isDirectory: &isDir), !isDir.boolValue else {
            return "Chemin refusé : « \(canon.path) » n'est pas un fichier lisible."
        }
        // Lecture bornée via FileHandle : on ne matérialise jamais plus de
        // maxFileBytes + 1 octets (le +1 détecte la troncature sans tout charger).
        guard let handle = try? FileHandle(forReadingFrom: canon) else {
            return "Impossible de lire « \(canon.path) »."
        }
        defer { try? handle.close() }
        let limit = Self.maxFileBytes + 1
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        let truncated = data.count > Self.maxFileBytes
        let capped = truncated ? data.prefix(Self.maxFileBytes) : data[...]
        // Binaire (UTF-8 raté) = refus, pas de mojibake renvoyé au LLM.
        guard let text = String(data: Data(capped), encoding: .utf8) else {
            return "Fichier refusé : « \(canon.path) » n'est pas un fichier texte (UTF-8)."
        }
        if text.isEmpty { return "Fichier vide : \(canon.path)" }
        return truncated
            ? "Source : \(canon.path)\n\(text)\n…[fichier tronqué : \(Self.maxFileBytes) octets conservés]"
            : "Source : \(canon.path)\n\(text)"
    }
}
