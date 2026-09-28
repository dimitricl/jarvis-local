import Foundation
import JarvisKit
import JarvisAgent

/// L2 — `bash` confiné : cwd = workspace, double barrière.
///
/// Barrière 1 (permissions) : motifs dangereux = `deny` (rm -rf, sudo,
/// curl/wget/ssh, osascript, redirections vers l'absolu…).
/// Barrière 2 (outil) : même refusé par le moteur, l'outil revalide ses
/// motifs avant d'exécuter — une règle trop permissive ne suffit pas à
/// lancer une suppression. Sortie plafonnée, échec = code + extrait.
public enum BashTool {
    public static func denyPatterns() -> [String] {
        ["rm -rf", "sudo", "curl", "wget", "ssh ", "osascript", "mkfs",
         "dd if=", ":(){", "chmod -R", "chown -R", "> /", ">> /", "| sh", "| bash"]
    }

    public static func isDenied(_ command: String) -> Bool {
        let lowered = command.lowercased()
        if lowered.hasPrefix("rm ") { return true }
        return denyPatterns().contains { lowered.contains($0) }
    }

    public static func definition(workspace: WorkspaceConfig) -> ToolDefinition {
        ToolDefinition(
            name: "bash",
            description: "Exécute une commande lecture-seule dans le workspace (ls, cat, echo, grep…).",
            parameters: WorkspaceTools.stringParams(["command": "commande"]),
            isWrite: true
        ) { args, _ in
            guard let command = args["command"].string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty
            else {
                return .failure(code: "bad_args", message: "Paramètre 'command' manquant.", hint: "Relis le schéma.")
            }
            if isDenied(command) {
                return .failure(code: "denied",
                                message: "Commande interdite par la politique outil.",
                                hint: "Utilise les outils fichiers (read/write/glob/grep) au lieu du shell.")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = workspace.root
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return .failure(code: "spawn_failed", message: "Commande non lançable.",
                                hint: "Utilise les outils fichiers plutôt que le shell.")
            }
            process.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                return .failure(code: "exit_\(process.terminationStatus)",
                                message: "Commande en échec (code \(process.terminationStatus)).",
                                hint: "Sortie : \(out.prefix(500))")
            }
            let capped = out.count > 2000 ? String(out.prefix(2000)) + "\n[tronqué]" : out
            return .success(JSONValue(capped))
        }
    }
}
