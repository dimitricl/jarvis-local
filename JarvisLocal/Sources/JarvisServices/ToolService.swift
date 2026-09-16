import Foundation
import JarvisCore

enum ToolServiceError: Error, CustomStringConvertible {
    case processTimeout(command: String, seconds: TimeInterval)

    var description: String {
        switch self {
        case .processTimeout(let command, let seconds):
            return "La commande « \(command) » n'a pas répondu après \(Int(seconds))s et a été interrompue."
        }
    }
}

/// Façade d'exécution d'outils (actor). Implémentation du protocol ToolExecutor
/// (JarvisCore) : l'orchestration ne retient que le protocol.
public actor ToolService: ToolExecutor {
    public static let shared = ToolService()

    /// Contexte partagé (un seul EKEventStore pour tous les domaines).
    /// Pourquoi : avant, chaque méthode créait son propre store — permissions
    /// en double et code non injectable en tests. `internal` pour les tests.
    let ctx: ToolContext
    private let calendar: CalendarTools
    private let reminders: RemindersTools
    private let messaging: MessagingTools
    private let system: SystemTools
    private let web = WebTools()
    private let notes = NotesTools()
    private let memory = MemoryTools()
    private let files = FileTools()
    /// Fournisseur MCP optionnel (chantier 5) : s'il connaît l'outil, il passe devant.
    var mcp: MCPToolProvider?

    private init(ctx: ToolContext = .live()) {
        self.ctx = ctx
        self.calendar = CalendarTools(ctx: ctx)
        self.reminders = RemindersTools(ctx: ctx)
        self.messaging = MessagingTools()
        self.system = SystemTools(ctx: ctx)
    }

    /// Compat : l'ancien runner statique vit désormais dans ProcessRunner.
    /// Gardé car des call-sites/tests l'utilisent encore.
    static func runProcess(executable: String, arguments: [String], timeout: TimeInterval = 45) async throws -> (stdout: String, stderr: String) {
        try await ProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout)
    }

    /// Injecte MCP au démarrage (composition root / executable).
    public func configureMCP(_ provider: MCPToolProvider?) { self.mcp = provider }

    /// Liste fusionnée envoyée à Ollama : natif + MCP dynamique.
    /// Quand MCP couvre une action, l'équivalent natif est MASQUÉ (table
    /// MCPToolProvider.nativeToMCP) pour ne pas exposer deux outils concurrents
    /// au modèle — mais il reste exécutable en fallback direct via execute().
    public func effectiveToolDefs() async -> [ToolDef] {
        guard let mcp else { return toolDefs }
        let extra = await mcp.toolDefs()
        let hidden = await mcp.supersededNativeTools()
        var seen = Set<String>()
        var out = toolDefs.filter { !hidden.contains($0.function.name) }
        seen.formUnion(out.map { $0.function.name })
        for d in extra where !seen.contains(d.function.name) {
            out.append(d); seen.insert(d.function.name)
        }
        return out
    }

    let toolDefs: [ToolDef] = [
        ToolDef(function: ToolFunction(
            name: "search_web",
            description: "Recherche sur le web. À utiliser pour : actualités, prix, météo, événements récents, données chiffrées, infos sur des personnes/entreprises/produits réels.",
            parameters: ToolParameters(
                properties: ["query": ToolProperty(type: "string", description: "La requête de recherche")],
                required: ["query"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "open_app",
            description: "Ouvre une application sur le Mac.",
            parameters: ToolParameters(
                properties: [
                    "app": ToolProperty(type: "string", description: "Nom exact de l'application (ex: Safari, Spotify, Messages)"),
                    "url": ToolProperty(type: "string", description: "URL ou nom de conversation (optionnel)")
                ],
                required: ["app"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "create_note",
            description: "Crée une NOUVELLE note dans Apple Notes.",
            parameters: ToolParameters(
                properties: [
                    "title": ToolProperty(type: "string", description: "Titre de la note"),
                    "body": ToolProperty(type: "string", description: "Contenu de la note")
                ],
                required: ["title", "body"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "edit_note",
            description: "MODIFIE une note existante dans Apple Notes.",
            parameters: ToolParameters(
                properties: [
                    "search_title": ToolProperty(type: "string", description: "Titre (ou partie) de la note à modifier"),
                    "body": ToolProperty(type: "string", description: "Nouveau contenu"),
                    "new_title": ToolProperty(type: "string", description: "Nouveau titre (optionnel)")
                ],
                required: ["search_title", "body"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "get_weather",
            description: "Donne la météo ACTUELLE d'une ville précise (température, conditions, vent). Utilise TOUJOURS cet outil pour toute question météo — jamais search_web, jamais add_reminder, jamais add_calendar_event. Une question météo n'est ni un rappel ni un événement de calendrier.",
            parameters: ToolParameters(
                properties: ["city": ToolProperty(type: "string", description: "Nom de la ville, ex: Muret, Toulouse, Paris")],
                required: ["city"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "add_reminder",
            description: "Ajoute un rappel dans Rappels. N'appelle CE tool QUE si l'utilisateur demande explicitement de créer/ajouter un rappel (\"rappelle-moi de...\", \"ajoute un rappel...\"). Ne jamais l'appeler en réponse à une simple question factuelle (météo, heure, info) — répondre à une question n'est pas créer un rappel.",
            parameters: ToolParameters(
                properties: [
                    "title": ToolProperty(type: "string", description: "Texte du rappel"),
                    "notes": ToolProperty(type: "string", description: "Notes (optionnel)"),
                    "due_date": ToolProperty(type: "string", description: "Date DD/MM/YYYY (optionnel)"),
                    "due_time": ToolProperty(type: "string", description: "Heure HH:MM (optionnel)")
                ],
                required: ["title"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "add_calendar_event",
            description: "Ajoute un événement dans Calendrier. N'appelle CE tool QUE si l'utilisateur demande explicitement de créer/ajouter un événement (\"ajoute à mon calendrier...\", \"programme un rendez-vous...\"). Ne jamais l'appeler en réponse à une simple question factuelle (météo, heure, info) — répondre à une question n'est pas créer un événement.",
            parameters: ToolParameters(
                properties: [
                    "title": ToolProperty(type: "string", description: "Titre"),
                    "date": ToolProperty(type: "string", description: "Date DD/MM/YYYY"),
                    "start_time": ToolProperty(type: "string", description: "Heure HH:MM (optionnel)"),
                    "duration_minutes": ToolProperty(type: "number", description: "Durée en minutes (optionnel)"),
                    "notes": ToolProperty(type: "string", description: "Notes (optionnel)"),
                    "calendar": ToolProperty(type: "string", description: "Nom du calendrier (optionnel)"),
                    "location": ToolProperty(type: "string", description: "Adresse (optionnel)")
                ],
                required: ["title", "date"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "get_calendars",
            description: "Liste les calendriers disponibles.",
            parameters: ToolParameters(properties: [:], required: [])
        )),
        ToolDef(function: ToolFunction(
            name: "search_maps",
            description: "Recherche un lieu dans Plans.",
            parameters: ToolParameters(
                properties: ["query": ToolProperty(type: "string", description: "Recherche")],
                required: ["query"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "run_shortcut",
            description: "Exécute un Raccourci macOS.",
            parameters: ToolParameters(
                properties: ["name": ToolProperty(type: "string", description: "Nom exact du raccourci")],
                required: ["name"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "send_message",
            description: "Envoie un message à un contact. Passe automatiquement par iMessage ou SMS selon le destinataire.",
            parameters: ToolParameters(
                properties: [
                    "contact": ToolProperty(type: "string", description: "Prénom/nom du destinataire"),
                    "message": ToolProperty(type: "string", description: "Contenu du message")
                ],
                required: ["contact", "message"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "get_system_info",
            description: "Retourne les infos système : RAM, CPU, disque, batterie, uptime, nom du Mac.",
            parameters: ToolParameters(properties: [:], required: [])
        )),
        ToolDef(function: ToolFunction(
            name: "get_clipboard",
            description: "Lit le contenu actuel du presse-papiers.",
            parameters: ToolParameters(properties: [:], required: [])
        )),
        ToolDef(function: ToolFunction(
            name: "set_clipboard",
            description: "Écrit du texte dans le presse-papiers.",
            parameters: ToolParameters(
                properties: ["text": ToolProperty(type: "string", description: "Texte à copier")],
                required: ["text"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "take_screenshot",
            description: "Prend une capture d'écran de tout l'écran.",
            parameters: ToolParameters(properties: [:], required: [])
        )),
        ToolDef(function: ToolFunction(
            name: "sleep_mac",
            description: "Action SUR LE MAC : met en veille ('sleep'), verrouille l'écran ('lock'), éteint ('shutdown') ou redémarre ('restart'). Appelle ce tool quand l'utilisateur dit 'va dormir', 'endors-toi', 'éteins le Mac', 'redémarre', 'verrouille l'écran' — ne confonds pas avec un souhait personnel.",
            parameters: ToolParameters(
                properties: ["action": ToolProperty(type: "string", description: "'sleep' pour veille | 'lock' pour verrouiller | 'shutdown' pour éteindre | 'restart' pour redémarrer")],
                required: ["action"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "file_search",
            description: "Recherche des fichiers sur le Mac par nom (moteur Spotlight).",
            parameters: ToolParameters(
                properties: ["query": ToolProperty(type: "string", description: "Nom du fichier à chercher")],
                required: ["query"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "get_upcoming_events",
            description: "Liste les prochains événements du calendrier.",
            parameters: ToolParameters(
                properties: ["days": ToolProperty(type: "number", description: "Nombre de jours à chercher (défaut: 7)")],
                required: []
            )
        )),
        ToolDef(function: ToolFunction(
            name: "read_url",
            description: "Retourne le texte brut et complet (jusqu'à 4000 caractères) d'une page web — prix, chiffres, tableaux et détails inclus. Sert à extraire des données précises d'une page dont l'URL est déjà connue. Différent de search_web : ici pas de recherche, lecture directe.",
            parameters: ToolParameters(
                properties: ["url": ToolProperty(type: "string", description: "URL complète à lire (avec https://)")],
                required: ["url"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "run_routine",
            description: "Exécute une routine enregistrée par l'utilisateur.",
            parameters: ToolParameters(
                properties: ["name": ToolProperty(type: "string", description: "Nom de la routine")],
                required: ["name"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "remember_fact",
            description: "Stocke une information personnelle sur l'utilisateur (nom, ville, préférences, allergies, etc.). Action rapide et passive qui ne remplace JAMAIS les autres actions demandées. Si tu as d'autres outils à appeler, appelle remember_fact EN PLUS, pas à la place.",
            parameters: ToolParameters(
                properties: [
                    "key": ToolProperty(type: "string", description: "Clé de l'information (ex: user.name, user.city, user.allergy, user.job, user.pet)"),
                    "value": ToolProperty(type: "string", description: "Valeur de l'information (ex: Dimitri, Paris, arachides, développeur, chat)")
                ],
                required: ["key", "value"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "list_reminders",
            description: "Liste les rappels en attente ou récents.",
            parameters: ToolParameters(
                properties: ["list": ToolProperty(type: "string", description: "Nom de la liste (optionnel)")],
                required: []
            )
        )),
        ToolDef(function: ToolFunction(
            name: "complete_reminder",
            description: "Marque un rappel comme terminé. Liste D'ABORD avec list_reminders pour obtenir son identifiant — jamais d'action sur un identifiant deviné ou un titre approximatif.",
            parameters: ToolParameters(
                properties: ["id": ToolProperty(type: "string", description: "Identifiant du rappel (issu de list_reminders)")],
                required: ["id"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "delete_reminder",
            description: "Supprime un rappel. Liste D'ABORD avec list_reminders pour obtenir son identifiant — jamais de suppression sur un identifiant deviné ou un titre approximatif.",
            parameters: ToolParameters(
                properties: ["id": ToolProperty(type: "string", description: "Identifiant du rappel (issu de list_reminders)")],
                required: ["id"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "edit_calendar_event",
            description: "MODIFIE un événement existant. Liste D'ABORD avec get_upcoming_events pour obtenir son identifiant — jamais de modification sur un identifiant deviné ou un titre approximatif. Champs absents = inchangés.",
            parameters: ToolParameters(
                properties: [
                    "id": ToolProperty(type: "string", description: "Identifiant de l'événement (issu de get_upcoming_events)"),
                    "title": ToolProperty(type: "string", description: "Nouveau titre (optionnel)"),
                    "date": ToolProperty(type: "string", description: "Nouvelle date DD/MM/YYYY (optionnel)"),
                    "start_time": ToolProperty(type: "string", description: "Nouvelle heure HH:MM (optionnel)"),
                    "duration_minutes": ToolProperty(type: "number", description: "Nouvelle durée en minutes (optionnel)"),
                    "notes": ToolProperty(type: "string", description: "Nouvelles notes (optionnel)"),
                    "location": ToolProperty(type: "string", description: "Nouvelle adresse (optionnel)"),
                    "calendar": ToolProperty(type: "string", description: "Nom du calendrier (optionnel)")
                ],
                required: ["id"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "delete_calendar_event",
            description: "Supprime un événement. Liste D'ABORD avec get_upcoming_events pour obtenir son identifiant — jamais de suppression sur un identifiant deviné ou un titre approximatif.",
            parameters: ToolParameters(
                properties: ["id": ToolProperty(type: "string", description: "Identifiant de l'événement (issu de get_upcoming_events)")],
                required: ["id"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "search_notes",
            description: "Recherche des notes Apple Notes par mot-clé (titre ou contenu). Retourne titre + identifiant — utilise ensuite read_note ou edit_note avec cet identifiant.",
            parameters: ToolParameters(
                properties: ["query": ToolProperty(type: "string", description: "Mot-clé à chercher")],
                required: ["query"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "read_note",
            description: "Lit le contenu COMPLET d'une note. Cherche D'ABORD avec search_notes pour obtenir son identifiant — jamais de lecture sur un titre approximatif deviné.",
            parameters: ToolParameters(
                properties: ["id": ToolProperty(type: "string", description: "Identifiant de la note (issu de search_notes)")],
                required: ["id"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "list_directory",
            description: "Liste le contenu d'un dossier. Sandbox : seuls les chemins sous ~/Documents, ~/Desktop ou ~/Downloads sont acceptés — tout autre chemin est refusé.",
            parameters: ToolParameters(
                properties: ["path": ToolProperty(type: "string", description: "Chemin du dossier (ex: ~/Documents)")],
                required: ["path"]
            )
        )),
        ToolDef(function: ToolFunction(
            name: "read_file",
            description: "Lit un fichier texte (plafonné à 200 Ko, binaires refusés). Sandbox : seuls les chemins sous ~/Documents, ~/Desktop ou ~/Downloads sont acceptés — tout autre chemin est refusé.",
            parameters: ToolParameters(
                properties: ["path": ToolProperty(type: "string", description: "Chemin du fichier (ex: ~/Documents/notes.txt)")],
                required: ["path"]
            )
        ))
    ]

    /// Extraction stricte : un paramètre requis absent ou mal typé ne vaut
    /// JAMAIS une valeur par défaut silencieuse ("", 0, 7…) qui ferait exécuter
    /// une action non demandée — le modèle reçoit un message explicite et corrige.
    /// `internal`/`static` pour les tests.
    nonisolated static func missingParam(_ key: String, tool: String) -> String {
        "Paramètre '\(key)' manquant ou de type invalide pour l'outil '\(tool)'"
    }

    /// Erreur de paramètre : enveloppe le message explicite renvoyé au modèle.
    /// `internal` pour les tests.
    struct ParamError: Error {
        let message: String
    }

    /// Requis String. `internal` pour les tests.
    nonisolated static func reqString(_ args: [String: Any], key: String, tool: String) -> Result<String, ParamError> {
        guard let v = args[key] as? String else { return .failure(ParamError(message: missingParam(key, tool: tool))) }
        return .success(v)
    }

    /// Optionnel String : absent = nil, présent mais non-String = erreur explicite.
    /// `internal` pour les tests.
    nonisolated static func optString(_ args: [String: Any], key: String, tool: String) -> Result<String?, ParamError> {
        guard let raw = args[key] else { return .success(nil) }
        guard let v = raw as? String else { return .failure(ParamError(message: missingParam(key, tool: tool))) }
        return .success(v)
    }

    /// Nombre optionnel avec défaut : absent = défaut, Int/Double/NSNumber
    /// acceptés (JSONSerialization), tout autre type = erreur explicite.
    /// `internal` pour les tests.
    nonisolated static func optInt(_ args: [String: Any], key: String, tool: String, default def: Int) -> Result<Int, ParamError> {
        guard let raw = args[key] else { return .success(def) }
        if let i = raw as? Int { return .success(i) }
        if let d = raw as? Double { return .success(Int(d)) }
        if let n = raw as? NSNumber { return .success(n.intValue) }
        return .failure(ParamError(message: missingParam(key, tool: tool)))
    }

    public func execute(name: String, args: [String: Any]) async throws -> String {
        // MCP d'abord si le nom matche un outil distant (chantier 5).
        if let mcp, await mcp.handles(tool: name) {
            return try await mcp.call(tool: name, args: args)
        }
        switch name {
        case "search_web":
            switch Self.reqString(args, key: "query", tool: name) {
            case .success(let q): return await web.searchWeb(q)
            case .failure(let err): return err.message
            }
        case "open_app":
            switch Self.reqString(args, key: "app", tool: name) {
            case .failure(let err): return err.message
            case .success(let app):
                switch Self.optString(args, key: "url", tool: name) {
                case .failure(let err): return err.message
                case .success(let url): return try await system.openApp(app, url: url)
                }
            }
        case "create_note":
            switch Self.reqString(args, key: "title", tool: name) {
            case .failure(let err): return err.message
            case .success(let title):
                switch Self.reqString(args, key: "body", tool: name) {
                case .failure(let err): return err.message
                case .success(let body): return try await notes.create(title: title, body: body)
                }
            }
        case "edit_note":
            switch Self.reqString(args, key: "search_title", tool: name) {
            case .failure(let err): return err.message
            case .success(let st):
                switch Self.reqString(args, key: "body", tool: name) {
                case .failure(let err): return err.message
                case .success(let body):
                    switch Self.optString(args, key: "new_title", tool: name) {
                    case .failure(let err): return err.message
                    case .success(let nt): return try await notes.edit(searchTitle: st, body: body, newTitle: nt)
                    }
                }
            }
        case "add_reminder":
            switch Self.reqString(args, key: "title", tool: name) {
            case .failure(let err): return err.message
            case .success(let title):
                switch Self.optString(args, key: "notes", tool: name) {
                case .failure(let err): return err.message
                case .success(let n):
                    switch Self.optString(args, key: "due_date", tool: name) {
                    case .failure(let err): return err.message
                    case .success(let dd):
                        switch Self.optString(args, key: "due_time", tool: name) {
                        case .failure(let err): return err.message
                        case .success(let dt): return try await reminders.add(title: title, notes: n, dueDate: dd, dueTime: dt)
                        }
                    }
                }
            }
        case "add_calendar_event": return try await calendar.addEvent(args: args)
        case "get_calendars": return try await calendar.getCalendars()
        case "search_maps":
            switch Self.reqString(args, key: "query", tool: name) {
            case .success(let q): return try await web.searchMaps(q)
            case .failure(let err): return err.message
            }
        case "run_shortcut":
            switch Self.reqString(args, key: "name", tool: name) {
            case .success(let n): return try await system.runShortcut(n)
            case .failure(let err): return err.message
            }
        case "send_message":
            switch Self.reqString(args, key: "contact", tool: name) {
            case .failure(let err): return err.message
            case .success(let contact):
                switch Self.reqString(args, key: "message", tool: name) {
                case .failure(let err): return err.message
                case .success(let message): return try await messaging.send(contact: contact, message: message)
                }
            }
        case "get_system_info": return try await system.getSystemInfo()
        case "get_clipboard": return await system.getClipboard()
        case "set_clipboard":
            switch Self.reqString(args, key: "text", tool: name) {
            case .success(let t): return await system.setClipboard(t)
            case .failure(let err): return err.message
            }
        case "take_screenshot": return try await system.takeScreenshot()
        case "sleep_mac":
            switch Self.reqString(args, key: "action", tool: name) {
            case .success(let a): return try await system.sleepMac(a)
            case .failure(let err): return err.message
            }
        case "file_search":
            switch Self.reqString(args, key: "query", tool: name) {
            case .success(let q): return try await system.fileSearch(q)
            case .failure(let err): return err.message
            }
        case "get_upcoming_events":
            switch Self.optInt(args, key: "days", tool: name, default: 7) {
            case .success(let d): return try await calendar.upcoming(days: d)
            case .failure(let err): return err.message
            }
        case "list_reminders":
            switch Self.optString(args, key: "list", tool: name) {
            case .success(let l): return try await reminders.list(list: l)
            case .failure(let err): return err.message
            }
        case "read_url":
            switch Self.reqString(args, key: "url", tool: name) {
            case .success(let u): return await web.readURL(u)
            case .failure(let err): return err.message
            }
        case "get_weather":
            switch Self.reqString(args, key: "city", tool: name) {
            case .success(let c): return await web.getWeather(city: c)
            case .failure(let err): return err.message
            }
        case "run_routine":
            switch Self.reqString(args, key: "name", tool: name) {
            case .success(let n): return try await runRoutine(n)
            case .failure(let err): return err.message
            }
        case "remember_fact":
            switch Self.reqString(args, key: "key", tool: name) {
            case .failure(let err): return err.message
            case .success(let k):
                switch Self.reqString(args, key: "value", tool: name) {
                case .failure(let err): return err.message
                case .success(let v): return await memory.remember(key: k, value: v)
                }
            }
        case "complete_reminder":
            switch Self.reqString(args, key: "id", tool: name) {
            case .success(let id): return try await reminders.complete(id: id)
            case .failure(let err): return err.message
            }
        case "delete_reminder":
            switch Self.reqString(args, key: "id", tool: name) {
            case .success(let id): return try await reminders.delete(id: id)
            case .failure(let err): return err.message
            }
        case "edit_calendar_event":
            switch Self.reqString(args, key: "id", tool: name) {
            case .failure(let err): return err.message
            case .success(let id):
                // Les champs optionnels mal typés sont refusés avec le même
                // contrat strict (pas de "notes: 42" silencieusement ignoré).
                for k in ["title", "date", "start_time", "notes", "location", "calendar"] {
                    if args[k] != nil, args[k] as? String == nil { return Self.missingParam(k, tool: name) }
                }
                if args["duration_minutes"] != nil {
                    let isNum = (args["duration_minutes"] as? Int) != nil
                        || (args["duration_minutes"] as? Double) != nil
                        || (args["duration_minutes"] as? NSNumber) != nil
                    if !isNum { return Self.missingParam("duration_minutes", tool: name) }
                }
                var changes = args
                changes.removeValue(forKey: "id")
                return try await calendar.editEvent(id: id, changes: changes)
            }
        case "delete_calendar_event":
            switch Self.reqString(args, key: "id", tool: name) {
            case .success(let id): return try await calendar.deleteEvent(id: id)
            case .failure(let err): return err.message
            }
        case "search_notes":
            switch Self.reqString(args, key: "query", tool: name) {
            case .failure(let err): return err.message
            case .success(let q):
                let hits = try await notes.search(query: q)
                if hits.isEmpty { return "Aucune note trouvée pour « \(q) »." }
                return hits.prefix(20).map { "- \($0.title) [id: \($0.id)]" }.joined(separator: "\n")
            }
        case "read_note":
            switch Self.reqString(args, key: "id", tool: name) {
            case .success(let id): return try await notes.read(id: id)
            case .failure(let err): return err.message
            }
        case "list_directory":
            switch Self.reqString(args, key: "path", tool: name) {
            case .success(let p): return await files.listDirectory(path: p)
            case .failure(let err): return err.message
            }
        case "read_file":
            switch Self.reqString(args, key: "path", tool: name) {
            case .success(let p): return await files.readFile(path: p)
            case .failure(let err): return err.message
            }
        default: return "Outil inconnu : \(name)"
        }
    }

    // MARK: - search_web (délégué chantier 1)

    private func searchWeb(_ query: String) async throws -> String {
        // Pourquoi `throws` conservé : signature du dispatcher inchangée ;
        // en pratique search() ne throw jamais (panne = texte explicite).
        return await web.searchWeb(query)
    }

    /// Alias de compat : l'ancien entry-point de mise en forme reste disponible
    /// pour les tests existants. L'implémentation pure vit dans JarvisCore
    /// (SearchResultFormatter) — ne pas étendre.
    /// `internal`/`static` pour les tests.
    nonisolated static func formatSearchResults(_ results: [(title: String, href: String, text: String?)]) -> String {
        SearchResultFormatter.format(results)
    }

    // MARK: - run_routine (orchestration, reste dans la façade)

    private func runRoutine(_ name: String) async throws -> String {
        switch name.lowercased() {
        case "morning", "matin":
            // Appels directs aux sous-services plutôt que via execute() : évite de
            // repasser par le dispatcher (et par MCP) pour un enchaînement interne
            // connu, et garde des erreurs isolées par étape.
            var parts: [String] = []

            if let events = try? await calendar.upcoming(days: 1), !events.isEmpty {
                parts.append("Aujourd'hui :\n\(events)")
            } else {
                parts.append("Aucun événement aujourd'hui.")
            }

            if let sysInfo = try? await system.getSystemInfo() {
                parts.append(sysInfo)
            }

            return parts.joined(separator: "\n\n")
        default:
            return "Routine \"\(name)\" inconnue. Routines disponibles : morning."
        }
    }
}
