import Foundation
import AppKit

/// Runner AppleScript RÉSERVÉ AUX TEMPLATES INTERNES FIGÉS (Messages, Notes, Plans).
/// L'outil générique `applescript` exposé au modèle a été SUPPRIMÉ (RCE triviale via
/// concaténation de chaînes, `tell app "Terminal"…`, etc. — une denylist sur texte
/// ne peut pas fermer cette classe de bug). Le LLM ne fournit plus jamais de code,
/// uniquement des paramètres validés (PowerAction, nom d'app, destinataire Contacts).
/// La denylist restante est de la défense en profondeur sur des templates déjà figés.
enum AppleScriptRunner {
    // NOTE DE SÉCURITÉ : liste noire sur du texte → défense en profondeur,
    // pas une garantie. AppleScript permet de reconstruire une chaîne
    // dynamiquement ("run script" sur texte assemblé…) : un contenu injecté
    // peut contourner le filtre. Le vrai filet reste la confirmation
    // utilisateur (applescript est dans sensitiveTools côté AppViewModel).
    private static let forbiddenPatterns: [NSRegularExpression] = {
        let patterns = [
            #"doshellscript"#, #"withadministratorprivileges"#,
            #"systemeventskeystroke"#, #"systemeventskeycode"#,
            #"runscript"#, #"loadscript"#, #"dojavascript"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    static func run(_ script: String) async throws -> String {
        // On ne garde que les alphanumériques : un "do¬shell script"
        // (continuation AppleScript) ou un commentaire inséré entre les mots
        // cassait la contiguïté de "doshellscript" et passait au travers.
        let flat = script.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
        for p in forbiddenPatterns where p.firstMatch(in: flat, range: NSRange(flat.startIndex..., in: flat)) != nil {
            return "Script refusé : commande dangereuse détectée (shell / privilèges admin / clavier via System Events / run-load script / do JavaScript)."
        }
        var error: NSDictionary?
        let result = try await MainActor.run { () -> NSAppleEventDescriptor? in
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
        if let e = error {
            return "Erreur AppleScript : \(e)"
        }
        return result?.stringValue ?? "Exécuté avec succès."
    }
}

/// Domaine Système : apps, raccourcis, infos, presse-papiers, capture, veille,
/// fichiers, AppleScript brut. Code déplacé à l'identique depuis ToolService.
/// Pourquoi un seul actor "système" et pas 7 micro-actors : ces outils
/// partagent `NSWorkspace` / `NSPasteboard` (main-thread) et `runProcess` ;
/// les séparer ajouterait du plumbing sans bénéfice de test.
actor SystemTools {
    private let ctx: ToolContext
    init(ctx: ToolContext = .live()) { self.ctx = ctx }

    // MARK: - open_app

    /// N'accepte que http/https : ni file://, ni schéma exotique. On ne préfixe
    /// en https que les chaînes SANS schéma explicite ("example.com") — jamais un
    /// "file://…" (sinon "https://file/…" deviendrait une URL http au host "file").
    /// NOTE : `internal`/`static` pour les tests.
    nonisolated static func httpURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let s = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty
        else { return nil }
        return u
    }

    func openApp(_ app: String, url: String?) async throws -> String {
        let nameMap: [String: String] = [
            "meteo": "Weather", "weather": "Weather",
            "calendrier": "Calendar", "calendar": "Calendar",
            "notes": "Notes", "mail": "Mail", "safari": "Safari",
            "chrome": "Google Chrome", "spotify": "Spotify",
            "telephone": "FaceTime", "facetime": "FaceTime",
            "messages": "Messages", "contacts": "Contacts",
            "musique": "Music", "music": "Music", "photos": "Photos",
            "reglages": "System Settings", "terminal": "Terminal",
            "finder": "Finder", "carte": "Maps", "maps": "Maps",
            "maison": "Home", "home": "Home",
            "vscode": "Visual Studio Code", "visual studio code": "Visual Studio Code",
            "code": "Visual Studio Code", "vs code": "Visual Studio Code",
            "calculatrice": "Calculator", "calc": "Calculator",
            "apercu": "Preview", "preview": "Preview",
            "discord": "Discord", "slack": "Slack",
            "whatsapp": "WhatsApp", "telegram": "Telegram",
            "notion": "Notion", "figma": "Figma", "steam": "Steam"
        ]

        let normalized = app.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let resolved = nameMap[normalized] ?? app

        if normalized == "messages", let contact = url, !contact.isEmpty {
            let script = """
            tell application "Messages"
                activate
                set targetService to 1st service whose service type = iMessage
                set found to false
                repeat with c in chats of targetService
                    try
                        set partName to name of participant 1 of c
                        if partName contains "\(contact.escapingForAppleScript)" then
                            open c
                            set found to true
                            exit repeat
                        end if
                    end try
                end repeat
                if found then
                    return "Conversation avec \(contact.escapingForAppleScript) ouverte."
                else
                    return "Conversation introuvable."
                end if
            end tell
            """
            return try await AppleScriptRunner.run(script)
        }

        let ws = NSWorkspace.shared
        // Bundle ID uniquement si la chaîne en a la forme (reverse-DNS) : sinon on passait
        // des noms d'apps à une API qui attend "com.apple.Safari" et elle échouait.
        var appURL: URL?
        if resolved.contains("."), !resolved.contains(" ") {
            appURL = ws.urlForApplication(withBundleIdentifier: resolved)
        }
        if appURL == nil, let path = bundlePath(for: resolved) {
            appURL = URL(fileURLWithPath: path)
        }
        if appURL == nil {
            appURL = await fuzzyFindApp(resolved)
        }
        if appURL == nil, let path = appStoreBundlePath(for: resolved) {
            appURL = URL(fileURLWithPath: path)
        }

        if let appURL {
            if let u = url {
                guard let urlObj = Self.httpURL(from: u) else {
                    return "URL refusée : http/https uniquement."
                }
                try await ws.open([urlObj], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                return "\(resolved) ouvert sur \(u)."
            }
            try await ws.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            return "\(resolved) ouvert."
        }
        if let u = url {
            guard let urlObj = Self.httpURL(from: u) else {
                return "URL refusée : http/https uniquement."
            }
            ws.open(urlObj)
            return "URL ouverte."
        }
        return "Application \(app) introuvable. Vérifie qu'elle est bien installée (dans /Applications ou ailleurs sur le disque)."
    }

    /// Recherche tolérante d'une app : scan insensible casse/accents des dossiers
    /// standards (exact puis partiel), puis Spotlight qui couvre TOUT le disque.
    /// AVANT : seul un chemin exact case-sensible était testé ; « VS Code » ne trouvait
    /// jamais « Visual Studio Code.app » et toute app hors des chemins codés en dur échouait.
    private func fuzzyFindApp(_ appName: String) async -> URL? {
        func fold(_ s: String) -> String {
            s.lowercased().folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        }
        let target = fold(appName)

        let dirs = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]

        // DEUX passes : exact d'abord sur tous les dossiers, partiel ensuite.
        // Sinon "Mail" matchait "Gmail.app" avant même de chercher l'exact ailleurs.
        for wantPartial in [false, true] {
            for dir in dirs {
                let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                let bundles = items.filter { $0.hasSuffix(".app") }
                if !wantPartial {
                    if let exact = bundles.first(where: { fold(String($0.dropLast(4))) == target }) {
                        return URL(fileURLWithPath: dir).appendingPathComponent(exact)
                    }
                } else {
                    let candidates = bundles
                        .filter { fold(String($0.dropLast(4))).contains(target) }
                        .sorted { $0.count < $1.count }
                    if let best = candidates.first {
                        return URL(fileURLWithPath: dir).appendingPathComponent(best)
                    }
                }
            }
        }

        // Le nom vient du modèle : on l'échappe pour le langage de requête mdfind
        // (guillemets doubles + backslash), sinon `"` casse la requête voire l'injecte.
        let safe = appName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let query = "kMDItemContentType == 'com.apple.application-bundle' && kMDItemDisplayName == \"\(safe)*\"cd"
        if let (out, _) = try? await ctx.runProcess("/usr/bin/mdfind", [query], 10) {
            if let line = out.components(separatedBy: "\n").first(where: { $0.hasSuffix(".app") }) {
                return URL(fileURLWithPath: line.trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    // MARK: - Shortcuts

    func runShortcut(_ name: String) async throws -> String {
        let (out, err) = try await ctx.runProcess("/usr/bin/shortcuts", ["run", name], 45)
        if !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Erreur Shortcut : \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Raccourci \"\(name)\" exécuté." : trimmed
    }

    // MARK: - get_system_info

    func getSystemInfo() async throws -> String {
        let diskURL = URL(fileURLWithPath: "/")
        let diskValues = try? diskURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let totalGB = (diskValues?.volumeTotalCapacity ?? 1) / 1_000_000_000
        let freeGB = (diskValues?.volumeAvailableCapacity ?? 0) / 1_000_000_000

        let ramBytes = try await shell("/usr/sbin/sysctl", ["-n", "hw.memsize"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ramGB = (UInt64(ramBytes) ?? 0) / 1_000_000_000

        let cpu = try await shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Batterie via pmset (instantané) plutôt que system_profiler (2-3s).
        let battText = try await shell("/usr/bin/pmset", ["-g", "batt"])
        let battLine = battText.components(separatedBy: "\n").first { $0.contains("%") } ?? ""
        let percentStr = battLine.components(separatedBy: "\t").last?
            .trimmingCharacters(in: .whitespaces)
        let batteryPercent = percentStr?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces) ?? "N/A"
        let chargeState = battLine.contains("charging") ? "en charge"
            : battLine.contains("charged") ? "chargée"
            : battLine.contains("discharging") ? "sur batterie"
            : "N/A"

        let bootStr = try await shell("/usr/sbin/sysctl", ["-n", "kern.boottime"])
        let bootSec = bootStr.components(separatedBy: "sec = ").last?.components(separatedBy: ",").first.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let uptimeDays = bootSec > 0 ? Int(Date().timeIntervalSince1970 - bootSec) / 86400 : 0

        return """
        Mac : \(ProcessInfo.processInfo.hostName)
        CPU : \(cpu)
        RAM : \(ramGB) Go
        Disque : \(freeGB) Go libres / \(totalGB) Go total
        Batterie : \(batteryPercent) (\(chargeState))
        Uptime : \(uptimeDays) jours
        """
    }

    private func shell(_ exec: String, _ args: [String]) async throws -> String {
        let (out, _) = try await ctx.runProcess(exec, args, 45)
        return out
    }

    // MARK: - Clipboard (AppKit = main thread uniquement)

    func getClipboard() async -> String {
        await MainActor.run {
            let pb = NSPasteboard.general
            guard let items = pb.pasteboardItems else { return "Presse-papiers vide." }
            let text = items.compactMap { $0.string(forType: .string) }.joined(separator: "\n")
            return text.isEmpty ? "Presse-papiers vide." : text
        }
    }

    func setClipboard(_ text: String) async -> String {
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            return "Texte copié dans le presse-papiers."
        }
    }

    // MARK: - take_screenshot

    func takeScreenshot() async throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let df = DateFormatter()
        df.dateFormat = "'Capture d\u{2019}\u{00E9}cran' yyyy-MM-dd '\u{00E0}' HH.mm.ss"
        let filename = "\(df.string(from: Date())).png"
        let path = tempDir.appendingPathComponent(filename).path
        let (_, err) = try await ctx.runProcess("/usr/sbin/screencapture", ["-x", path], 45)
        if !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Erreur capture : \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        await MainActor.run { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        return "Capture d'écran enregistrée et ouverte : \(filename) (ouverte dans Aperçu)"
    }

    // MARK: - sleep_mac (allowlist typée)

    /// Le modèle ne fournit que la raw value d'un enum fermé, jamais du code ni une
    /// commande. Il n'y a rien à filtrer parce qu'il n'y a rien de variable.
    /// NOTE : `internal` pour les tests.
    enum PowerAction: String, CaseIterable, Sendable {
        case sleep, lock, shutdown, restart

        /// Alias français acceptés (le modèle parle français).
        /// NOTE : `internal` pour les tests.
        init?(userInput: String) {
            switch userInput.lowercased().folding(options: .diacriticInsensitive, locale: .current) {
            case "sleep", "veille": self = .sleep
            case "lock", "verrouiller": self = .lock
            case "shutdown", "eteindre": self = .shutdown
            case "restart", "redemarrer": self = .restart
            default: return nil
            }
        }
    }

    func sleepMac(_ action: String) async throws -> String {
        guard let power = PowerAction(userInput: action) else {
            return "Action inconnue. Utilise sleep, lock, shutdown ou restart."
        }
        return try await setPower(power)
    }

    /// Exécute une action typée. Commandes et scripts FIGÉS, zéro interpolation
    /// de texte LLM : la classe "injection AppleScript/shell" est éliminée, pas filtrée.
    func setPower(_ action: PowerAction) async throws -> String {
        switch action {
        case .sleep:
            afterSpeechThen {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                proc.arguments = ["sleepnow"]
                try? proc.run()
            }
            return "Mise en veille."
        case .lock:
            _ = try? await ctx.runProcess(
                "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession",
                ["-suspend"], 45
            )
            return "Mac verrouillé."
        case .shutdown:
            afterSpeechThen {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                proc.arguments = ["shutdown", "now"]
                try? proc.run()
            }
            return "Extinction."
        case .restart:
            // NSAppleScript est main-thread-only : hop explicite. Avant, ce script
            // s'exécutait sur le thread de fond d'afterSpeechThen → crash/UB.
            afterSpeechThen {
                Task { @MainActor in
                    var error: NSDictionary?
                    _ = NSAppleScript(source: #"tell application "System Events" to restart"#)?.executeAndReturnError(&error)
                }
            }
            return "Redémarrage."
        }
    }

    /// Décale l'action système après la fin du TTS : éteindre pendant que
    /// Jarvis dit "Bonne nuit" coupait la parole au milieu du mot.
    /// `nonisolated` : appelé depuis l'actor mais ne touche aucun état isolé.
    private nonisolated func afterSpeechThen(_ action: @escaping () -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            var waited: UInt64 = 0
            let maxWait: UInt64 = 15_000_000_000
            while waited < maxWait {
                let done = await MainActor.run { !AudioService.shared.isSpeaking }
                if done { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 500_000_000
            }
            action()
        }
    }

    // MARK: - file_search

    func fileSearch(_ query: String) async throws -> String {
        let (out, err) = try await ctx.runProcess("/usr/bin/mdfind", ["-literal", query, "-maxresults", "10"], 45)
        if !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Erreur : \(err)" }

        let results = out.components(separatedBy: "\n").filter { !$0.isEmpty }
        if results.isEmpty { return "Aucun fichier trouvé pour \"\(query)\"." }
        if results.count >= 10 { return "Résultats (10 max) :\n" + results.prefix(10).joined(separator: "\n") }
        return "Résultats :\n" + results.joined(separator: "\n")
    }
}

/// Find bundle path by app name (common locations).
/// Pourquoi en free function : utilisé uniquement par SystemTools, pas d'état.
func bundlePath(for appName: String) -> String? {
    let paths = [
        "/Applications/\(appName).app",
        "/Applications/Utilities/\(appName).app",
        "/System/Applications/\(appName).app",
        "/System/Applications/Utilities/\(appName).app",
        "\(NSHomeDirectory())/Applications/\(appName).app"
    ]
    return paths.first { FileManager.default.fileExists(atPath: $0) }
}

/// Fallback: lookup by bundle identifier.
func appStoreBundlePath(for appName: String) -> String? {
    let bundleIDs: [String: String] = [
        "Safari": "com.apple.Safari",
        "Calendar": "com.apple.iCal",
        "Notes": "com.apple.Notes",
        "Mail": "com.apple.mail",
        "Messages": "com.apple.MobileSMS",
        "Maps": "com.apple.Maps",
        "Music": "com.apple.Music",
        "Photos": "com.apple.Photos",
        "FaceTime": "com.apple.FaceTime",
        "Contacts": "com.apple.AddressBook",
        "Finder": "com.apple.finder",
        "Terminal": "com.apple.Terminal",
        "System Settings": "com.apple.systempreferences",
        "Weather": "com.apple.weather",
        "Home": "com.apple.home"
    ]
    guard let bid = bundleIDs[appName] ?? bundleIDs[appName.lowercased()] else { return nil }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return nil }
    return url.path
}
