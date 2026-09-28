import Foundation
import JarvisKit
import JarvisAgent
import JarvisServices

/// L2 — outils fichiers_INDIV dans un workspace, garde-fous repris de
/// `FileTools` (résolution canonique, fail-closed) : `..`, absolu hors
/// workspace, symlink fuyant = refus explicite. Contrairement au périmètre
/// v0.9.1 (~/Documents…), le workspace est injecté (bac d'eval, dossier de
/// travail phase 3) — jamais de chemin en dur.
public struct WorkspaceConfig: Sendable {
    public var root: URL
    public var maxReadBytes: Int

    public init(root: URL, maxReadBytes: Int = 200_000) {
        self.root = root.standardized
        self.maxReadBytes = maxReadBytes
    }

    /// Résolution canonique fail-closed DANS le workspace.
    public func resolve(_ rawPath: String) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return nil }
        let candidate = root.appendingPathComponent(trimmed)
        let resolved = candidate.resolvingSymlinksInPath().standardized
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else { return nil }
        return resolved
    }
}

public enum WorkspaceTools {
    public static func definitions(workspace: WorkspaceConfig) -> [ToolDefinition] {
        [read(workspace: workspace), write(workspace: workspace), edit(workspace: workspace),
         glob(workspace: workspace), grep(workspace: workspace)]
    }

    static func read(workspace: WorkspaceConfig) -> ToolDefinition {
        ToolDefinition(
            name: "read_file",
            description: "Lit un fichier texte du workspace (chemin relatif).",
            parameters: stringParams(["path": "chemin relatif"])
        ) { args, _ in
            guard let path = args["path"].string, !path.isEmpty else {
                return .failure(code: "bad_args", message: "Paramètre 'path' manquant.", hint: "Relis le schéma.")
            }
            guard let url = workspace.resolve(path) else {
                return .failure(code: "refused", message: "Chemin hors workspace : \(path).",
                                hint: "N'utilise que des chemins relatifs au workspace, sans « .. ».")
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .failure(code: "not_found", message: "Fichier absent : \(path).",
                                hint: "Vérifie avec glob, ou crée-le avec write_file. N'invente pas son contenu.")
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return .failure(code: "unreadable", message: "Fichier illisible : \(path).", hint: "Décris l'échec.")
            }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: workspace.maxReadBytes + 1)) ?? Data()
            if data.count > workspace.maxReadBytes {
                return .failure(code: "too_large", message: "Fichier > \(workspace.maxReadBytes) octets.",
                                hint: "Utilise grep pour cibler un extrait.")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure(code: "binary", message: "Fichier non-UTF-8 (binaire ?) : \(path).",
                                hint: "Décris l'échec au lieu d'inventer.")
            }
            return .success(JSONValue(text))
        }
    }

    static func write(workspace: WorkspaceConfig) -> ToolDefinition {
        ToolDefinition(
            name: "write_file",
            description: "Écrit (crée/remplace) un fichier du workspace.",
            parameters: stringParams(["path": "chemin relatif", "content": "contenu"]),
            isWrite: true
        ) { args, _ in
            guard let path = args["path"].string, !path.isEmpty else {
                return .failure(code: "bad_args", message: "Paramètre 'path' manquant.", hint: "Relis le schéma.")
            }
            guard let url = workspace.resolve(path) else {
                return .failure(code: "refused", message: "Chemin hors workspace : \(path).",
                                hint: "N'utilise que des chemins relatifs au workspace.")
            }
            let content = args["content"].string ?? ""
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
                return .success(JSONValue("Écrit : \(path) (\(content.utf8.count) octets)."))
            } catch {
                return .failure(code: "io_error", message: "Écriture impossible : \(path).", hint: "Décris l'échec.")
            }
        }
    }

    static func edit(workspace: WorkspaceConfig) -> ToolDefinition {
        ToolDefinition(
            name: "edit_file",
            description: "Remplacement exact UNIQUE dans un fichier du workspace.",
            parameters: stringParams(["path": "chemin", "old": "texte exact", "new": "nouveau texte"]),
            isCore: false,
            isWrite: true
        ) { args, _ in
            guard let path = args["path"].string,
                  let old = args["old"].string,
                  let new = args["new"].string
            else {
                return .failure(code: "bad_args", message: "Paramètres 'path', 'old', 'new' requis.",
                                hint: "Relis le schéma.")
            }
            guard let url = workspace.resolve(path),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else {
                return .failure(code: "not_found", message: "Fichier absent ou illisible : \(path).",
                                hint: "Lis-le d'abord avec read_file.")
            }
            let occurrences = text.components(separatedBy: old).count - 1
            guard occurrences == 1 else {
                return .failure(code: "not_unique",
                                message: "Remplacement non unique (\(occurrences) occurrences).",
                                hint: "Élargis 'old' pour viser une occurrence unique.")
            }
            do {
                try text.replacingOccurrences(of: old, with: new)
                    .write(to: url, atomically: true, encoding: .utf8)
                return .success(JSONValue("Édité : \(path)."))
            } catch {
                return .failure(code: "io_error", message: "Écriture impossible.", hint: "Décris l'échec.")
            }
        }
    }

    static func glob(workspace: WorkspaceConfig) -> ToolDefinition {
        ToolDefinition(
            name: "glob",
            description: "Liste les fichiers du workspace (* ou *.ext).",
            parameters: stringParams(["pattern": "motif"])
        ) { args, _ in
            let pattern = args["pattern"].string ?? "*"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: workspace.root.path)) ?? []
            let matched: [String]
            if pattern == "*" {
                matched = names.sorted()
            } else if pattern.hasPrefix("*.") {
                let ext = String(pattern.dropFirst(2))
                matched = names.filter { $0.hasSuffix("." + ext) }.sorted()
            } else {
                matched = names.filter { $0 == pattern }.sorted()
            }
            return .success(JSONValue(matched.joined(separator: "\n")))
        }
    }

    static func grep(workspace: WorkspaceConfig) -> ToolDefinition {
        ToolDefinition(
            name: "grep",
            description: "Cherche une sous-chaîne dans les fichiers texte du workspace.",
            parameters: stringParams(["pattern": "texte cherché"])
        ) { args, _ in
            guard let pattern = args["pattern"].string, !pattern.isEmpty else {
                return .failure(code: "bad_args", message: "Paramètre 'pattern' manquant.", hint: "Relis le schéma.")
            }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: workspace.root.path)) ?? []).sorted()
            var hits: [String] = []
            for name in names {
                let url = workspace.root.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? handle.close() }
                guard let data = try? handle.read(upToCount: workspace.maxReadBytes),
                      let text = String(data: data, encoding: .utf8),
                      text.contains(pattern)
                else { continue }
                hits.append("\(name): \(text.prefix(160))")
            }
            if hits.isEmpty { return .success(JSONValue("Aucun résultat pour '\(pattern)'.")) }
            return .success(JSONValue(hits.joined(separator: "\n")))
        }
    }

    static func stringParams(_ props: [String: String]) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for (k, v) in props {
            properties[k] = .object(["type": .string("string"), "description": .string(v)])
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(props.keys.sorted().map { .string($0) }),
        ])
    }
}
