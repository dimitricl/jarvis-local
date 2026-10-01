import Foundation
import JarvisKit
import JarvisAgent

/// L2 — intégrations macOS : `applescript`, `open`, `screenshot`,
/// `clipboard_get/set`, `notify`.
///
/// Chaque effet passe par un runner injecté (prod / fake / lecture-seule) :
/// testables sans effet réel. `screenshot` renvoie le PNG en base64 dans
/// `data` (l'envoi image au modèle vision suit en phase 3, côté provider).
public struct MacConfig: Sendable {
    public var applescript: any AppleScriptRunner
    public var opener: any URLOpener
    public var screenshotter: any Screenshotter
    public var clipboard: any Clipboard
    public var notifier: any Notifier

    public init(
        applescript: any AppleScriptRunner = LiveAppleScriptRunner(),
        opener: any URLOpener = LiveURLOpener(),
        screenshotter: any Screenshotter = LiveScreenshotter(),
        clipboard: any Clipboard = LiveClipboard(),
        notifier: any Notifier = LiveNotifier()
    ) {
        self.applescript = applescript
        self.opener = opener
        self.screenshotter = screenshotter
        self.clipboard = clipboard
        self.notifier = notifier
    }

    public static func fakes() -> MacConfig {
        MacConfig(
            applescript: FakeAppleScriptRunner(canned: [
                "rappel": "2 rappels : 'relire bilan', 'appeler Alice' (simulé).",
                "demo": "Événement 'Demo' créé demain 10h (simulé).",
                "document": "Document courant : 'Notes de test' (simulé).",
                "activate": "Application lancée (simulé).",
                "launch": "Application lancée (simulé).",
            ]),
            opener: FakeURLOpener(),
            screenshotter: FakeScreenshotter(),
            clipboard: FakeClipboard(content: "relire le bilan demain"),
            notifier: FakeNotifier())
    }
}

public enum MacTools {
    public static func definitions(config: MacConfig = MacConfig()) -> [ToolDefinition] {
        [applescript(config: config), open(config: config), screenshot(config: config),
         clipboardGet(config: config), clipboardSet(config: config), notify(config: config)]
    }

    static func applescript(config: MacConfig) -> ToolDefinition {
        ToolDefinition(
            name: "applescript",
            description: "Contrôle une application macOS via AppleScript (lecture et actions simples).",
            parameters: WorkspaceTools.stringParams(["script": "script AppleScript"]),
            isCore: false,
            isWrite: true
        ) { args, _ in
            guard let script = args["script"].string, !script.isEmpty else {
                return .failure(code: "bad_args", message: "Paramètre 'script' manquant.", hint: "Relis le schéma.")
            }
            do {
                let out = try await config.applescript.run(script: script)
                return .success(JSONValue(out.isEmpty ? "AppleScript exécuté (sans sortie)." : out))
            } catch {
                return .failure(code: "script_error", message: "AppleScript en échec : \(error).",
                                hint: "Simplifie le script ou décris l'échec.")
            }
        }
    }

    static func open(config: MacConfig) -> ToolDefinition {
        ToolDefinition(
            name: "open",
            description: "Ouvre une application, un fichier ou une URL.",
            parameters: WorkspaceTools.stringParams(["target": "nom d'app, chemin ou URL"]),
            isCore: false,
            isNetworkEgress: true,
            isWrite: true
        ) { args, _ in
            // Tolérance : le modèle calque la convention dominante (`path`)
            // au lieu de `target` (constaté : `open(path="mail")` → bad_args
            // ×2 puis stall). Schéma inchangé, on accepte les deux.
            let raw = args["target"].string ?? args["path"].string ?? ""
            let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else {
                return .failure(code: "bad_args", message: "Paramètre 'target' (ou 'path') manquant.", hint: "Relis le schéma.")
            }
            do {
                return .success(JSONValue(try await config.opener.open(target: target)))
            } catch {
                return .failure(code: "open_failed", message: "Ouverture impossible : \(target).",
                                hint: "Vérifie la cible.")
            }
        }
    }

    static func screenshot(config: MacConfig) -> ToolDefinition {
        ToolDefinition(
            name: "screenshot",
            description: "Capture l'écran (PNG écrit dans ~/.local/share/jarvis/captures/, renvoie path + dimensions).",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            isCore: false
        ) { _, _ in
            do {
                let (path, width, height) = try await config.screenshotter.captureToFile()
                return .success(.object([
                    "path": .string(path),
                    "width": .int(width),
                    "height": .int(height),
                ]))
            } catch {
                return .failure(code: "capture_failed", message: "Capture impossible.", hint: "Décris l'échec.")
            }
        }
    }

    static func clipboardGet(config: MacConfig) -> ToolDefinition {
        ToolDefinition(
            name: "clipboard_get",
            description: "Lit le presse-papiers.",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            isCore: false,
            producesUntrustedContent: true
        ) { _, _ in
            .success(JSONValue(await config.clipboard.get()))
        }
    }

    static func clipboardSet(config: MacConfig) -> ToolDefinition {
        ToolDefinition(
            name: "clipboard_set",
            description: "Écrit dans le presse-papiers.",
            parameters: WorkspaceTools.stringParams(["text": "texte"]),
            isCore: false,
            isWrite: true
        ) { args, _ in
            do {
                try await config.clipboard.set(args["text"].string ?? "")
                return .success(JSONValue("Presse-papiers mis à jour."))
            } catch {
                return .failure(code: "clipboard_failed", message: "Écriture impossible.", hint: "Décris l'échec.")
            }
        }
    }

    static func notify(config: MacConfig) -> ToolDefinition {
        ToolDefinition(
            name: "notify",
            description: "Affiche une notification locale.",
            parameters: WorkspaceTools.stringParams(["message": "texte"])
        ) { args, _ in
            do {
                try await config.notifier.notify(message: args["message"].string ?? "")
                return .success(JSONValue("Notification affichée."))
            } catch {
                return .failure(code: "notify_failed", message: "Notification impossible.", hint: "Décris l'échec.")
            }
        }
    }
}
