import Foundation

enum ToolServiceError: Error, CustomStringConvertible {
    case processTimeout(command: String, seconds: TimeInterval)

    var description: String {
        switch self {
        case .processTimeout(let command, let seconds):
            return "La commande « \(command) » n'a pas répondu après \(Int(seconds))s et a été interrompue."
        }
    }
}

actor ToolService {
    static let shared = ToolService()

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

    /// Injecte MCP au démarrage (JarvisLocalApp / AppViewModel).
    func configureMCP(_ provider: MCPToolProvider?) { self.mcp = provider }

    /// Liste fusionnée envoyée à Ollama : natif + MCP dynamique.
    /// Le natif garde la priorité sauf outils explicitement délégués
    /// (voir MCPToolProvider.delegatedToMCP + nativeOnly).
    func effectiveToolDefs() async -> [ToolDef] {
        guard let mcp else { return toolDefs }
        let extra = await mcp.toolDefs()
        var seen = Set(toolDefs.map { $0.function.name })
        var out = toolDefs
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
            name: "applescript",
            description: "Exécute un script AppleScript.",
            parameters: ToolParameters(
                properties: ["script": ToolProperty(type: "string", description: "Le code AppleScript")],
                required: ["script"]
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
            description: "Lit et résume le contenu texte d'une URL précise fournie par l'utilisateur. Différent de search_web : ici l'URL est déjà connue, pas de recherche.",
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
        ))
    ]

    func execute(name: String, args: [String: Any]) async throws -> String {
        // MCP d'abord si le nom matche un outil distant (chantier 5).
        if let mcp, await mcp.handles(tool: name) {
            return try await mcp.call(tool: name, args: args)
        }
        switch name {
        case "search_web": return await web.searchWeb(args["query"] as? String ?? "")
        case "open_app": return try await system.openApp(args["app"] as? String ?? "", url: args["url"] as? String)
        case "create_note": return try await notes.create(title: args["title"] as? String ?? "", body: args["body"] as? String ?? "")
        case "edit_note": return try await notes.edit(searchTitle: args["search_title"] as? String ?? "", body: args["body"] as? String ?? "", newTitle: args["new_title"] as? String)
        case "applescript": return try await system.runAppleScript(args["script"] as? String ?? "")
        case "add_reminder": return try await reminders.add(title: args["title"] as? String ?? "", notes: args["notes"] as? String, dueDate: args["due_date"] as? String, dueTime: args["due_time"] as? String)
        case "add_calendar_event": return try await calendar.addEvent(args: args)
        case "get_calendars": return try await calendar.getCalendars()
        case "search_maps": return try await web.searchMaps(args["query"] as? String ?? "")
        case "run_shortcut": return try await system.runShortcut(args["name"] as? String ?? "")
        case "send_message": return try await messaging.send(contact: args["contact"] as? String ?? "", message: args["message"] as? String ?? "")
        case "get_system_info": return try await system.getSystemInfo()
        case "get_clipboard": return await system.getClipboard()
        case "set_clipboard": return await system.setClipboard(args["text"] as? String ?? "")
        case "take_screenshot": return try await system.takeScreenshot()
        case "sleep_mac": return try await system.sleepMac(args["action"] as? String ?? "")
        case "file_search": return try await system.fileSearch(args["query"] as? String ?? "")
        case "get_upcoming_events": return try await calendar.upcoming(days: args["days"] as? Int ?? 7)
        case "list_reminders": return try await reminders.list(list: args["list"] as? String)
        case "read_url": return await web.readURL(args["url"] as? String ?? "")
        case "get_weather": return await web.getWeather(city: args["city"] as? String ?? "")
        case "run_routine": return try await runRoutine(args["name"] as? String ?? "")
        case "remember_fact": return await memory.remember(key: args["key"] as? String ?? "", value: args["value"] as? String ?? "")
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
    /// pour les tests existants. Délègue au formateur canonique.
    /// `internal`/`static` pour les tests.
    nonisolated static func formatSearchResults(_ results: [(title: String, href: String, text: String?)]) -> String {
        WebSearchService.format(results)
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

