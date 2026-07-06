import Foundation
import EventKit
import MapKit
import Speech
import Contacts

actor ToolService {
    static let shared = ToolService()
    private let eventStore = EKEventStore()

    private init() {}

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
        switch name {
        case "search_web": return try await searchWeb(args["query"] as? String ?? "")
        case "open_app": return try await openApp(args["app"] as? String ?? "", url: args["url"] as? String)
        case "create_note": return try await createNote(title: args["title"] as? String ?? "", body: args["body"] as? String ?? "")
        case "edit_note": return try await editNote(searchTitle: args["search_title"] as? String ?? "", body: args["body"] as? String ?? "", newTitle: args["new_title"] as? String)
        case "applescript": return try await runAppleScript(args["script"] as? String ?? "")
        case "add_reminder": return try await addReminder(title: args["title"] as? String ?? "", notes: args["notes"] as? String, dueDate: args["due_date"] as? String, dueTime: args["due_time"] as? String)
        case "add_calendar_event": return try await addCalendarEvent(args: args)
        case "get_calendars": return try await getCalendars()
        case "search_maps": return try await searchMaps(args["query"] as? String ?? "")
        case "run_shortcut": return try await runShortcut(args["name"] as? String ?? "")
        case "send_message": return try await sendMessage(contact: args["contact"] as? String ?? "", message: args["message"] as? String ?? "")
        case "get_system_info": return try await getSystemInfo()
        case "get_clipboard": return getClipboard()
        case "set_clipboard": return setClipboard(args["text"] as? String ?? "")
        case "take_screenshot": return try await takeScreenshot()
        case "sleep_mac": return try await sleepMac(args["action"] as? String ?? "")
        case "file_search": return try await fileSearch(args["query"] as? String ?? "")
        case "get_upcoming_events": return try await getUpcomingEvents(days: args["days"] as? Int ?? 7)
        case "list_reminders": return try await listReminders(list: args["list"] as? String)
        case "read_url": return try await readURL(args["url"] as? String ?? "")
        case "get_weather": return try await getWeather(city: args["city"] as? String ?? "")
        case "run_routine": return try await runRoutine(args["name"] as? String ?? "")
        case "remember_fact": return await rememberFact(key: args["key"] as? String ?? "", value: args["value"] as? String ?? "")
        default: return "Outil inconnu : \(name)"
        }
    }

    // MARK: - search_web

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Fetch générique réutilisé par search_web et read_url. UA de navigateur + timeout court :
    /// une requête qui traîne ne doit jamais bloquer tout le tour de conversation.
    private func fetchPage(_ url: URL, timeout: TimeInterval) async -> String? {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        return html
    }

    private func searchWeb(_ query: String) async throws -> String {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://lite.duckduckgo.com/lite/?q=\(encoded)")
        else { return "Erreur d'encodage de la requête." }

        // DuckDuckGo Lite répond parfois différemment (voire refuse) sans User-Agent de navigateur,
        // et l'ancien code utilisait le timeout par défaut de 120s de la session partagée : une requête
        // qui traîne bloquait tout le tour de conversation. Ici : UA dédié + timeout court, et toute
        // erreur réseau retourne un résultat textuel plutôt que de faire planter tout le tour (try await
        // qui remonte jusqu'au catch générique de runConversationTurn).
        guard let html = await fetchPage(searchURL, timeout: 15) else {
            return "Recherche web indisponible (pas de réponse de DuckDuckGo). Réponds avec tes connaissances générales en précisant que tu n'as pas pu vérifier en ligne."
        }

        var results: [(title: String, href: String)] = []
        let patterns = [
            #"<a[^>]*class="result-link"[^>]*href="([^"]*)"[^>]*>([^<]*)</a>"#,
            #"<a[^>]*href="([^"]*)"[^>]*class="result-link"[^>]*>([^<]*)</a>"#,
            #"<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>([^<]*)</a>"#,
            #"<a[^>]*rel="nofollow"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#,
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                for m in matches.prefix(5) {
                    let hrefRange = m.range(at: 1)
                    let titleRange = m.range(at: 2)
                    guard hrefRange.location != NSNotFound, titleRange.location != NSNotFound,
                          let href = Range(hrefRange, in: html).map({ String(html[$0]) }),
                          let title = Range(titleRange, in: html).map({ String(html[$0]).strippedHTML }),
                          !href.isEmpty, !title.isEmpty
                    else { continue }
                    results.append((title: title, href: href))
                }
            }
            if !results.isEmpty { break }
        }

        if results.isEmpty {
            return "Aucun résultat trouvé pour \"\(query)\". Le format de la page DuckDuckGo a peut-être changé, ou la requête n'a rien donné."
        }

        var output = ""
        for r in results.prefix(3) {
            // href peut être relatif ("//duckduckgo.com/l/?uddg=...") : on le résout par rapport à l'URL de recherche
            // au lieu du force-unwrap précédent (URL(string:)! plantait l'app si le lien était malformé).
            guard let resultURL = URL(string: r.href, relativeTo: searchURL) else { continue }
            output += "--- \(r.title) ---\n"
            if let pageHTML = await fetchPage(resultURL, timeout: 10) {
                let text = pageHTML.htmlToText(maxLength: 3000)
                if text.count > 100 {
                    output += "Contenu : \(text)\n"
                }
            }
            output += "\n"
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - open_app

    private func openApp(_ app: String, url: String?) async throws -> String {
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
            "maison": "Home", "home": "Home"
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
            return try await runAppleScript(script)
        }

        let ws = NSWorkspace.shared
        if let appURL = ws.urlForApplication(withBundleIdentifier: resolved)
            ?? bundlePath(for: resolved).map({ URL(fileURLWithPath: $0) })
            ?? appStoreBundlePath(for: resolved).map({ URL(fileURLWithPath: $0) })
        {
            if let u = url {
                let urlStr = u.hasPrefix("http") ? u : "https://\(u)"
                if let urlObj = URL(string: urlStr) {
                    try await ws.open([urlObj], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                    return "\(resolved) ouvert sur \(u)."
                }
            }
            try await ws.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            return "\(resolved) ouvert."
        }
        if let u = url {
            let urlStr = u.hasPrefix("http") ? u : "https://\(u)"
            if let urlObj = URL(string: urlStr) {
                ws.open(urlObj)
                return "URL ouverte."
            }
        }
        return "Application \(app) introuvable."
    }

    // MARK: - Notes

    private func createNote(title: String, body: String) async throws -> String {
        let script = """
        tell application "Notes"
            set n to make new note with properties {name:"\(title.escapingForAppleScript)", body:"\(body.escapingForAppleScript)"}
            show n
        end tell
        """
        return try await runAppleScript(script)
    }

    private func editNote(searchTitle: String, body: String, newTitle: String?) async throws -> String {
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
        return try await runAppleScript(script)
    }

    // MARK: - AppleScript

    // NOTE DE SÉCURITÉ : ceci reste une liste noire sur du texte -> défense en profondeur,
    // pas une garantie. AppleScript permet de reconstruire une chaîne dynamiquement (concaténation
    // "&", "run script" sur du texte assemblé au runtime, etc.) : un modèle halluciné ou un contenu
    // injecté peut en théorie construire "do shell script" sans que la commande apparaisse jamais
    // telle quelle dans le script source. Le vrai filet de sécurité reste la confirmation utilisateur
    // obligatoire (applescript est dans sensitiveTools côté AppViewModel) : ce filtre bloque les cas
    // évidents et non-obfusqués, il ne remplace pas la lecture du script par un humain avant de
    // cliquer "Confirmer".
    private let forbiddenPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"doshellscript"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"withadministratorprivileges"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"systemeventskeystroke"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"systemeventskeycode"#, options: [.caseInsensitive]),
        // Élargissement : "run script"/"load script"/"do javascript" exécutent du code arbitraire
        // construit dynamiquement ou chargé depuis un fichier — même surface de risque que
        // do shell script, absents de la version précédente.
        try! NSRegularExpression(pattern: #"runscript"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"loadscript"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"dojavascript"#, options: [.caseInsensitive]),
    ]

    private func runAppleScript(_ script: String) async throws -> String {
        // Avant : on ne retirait que les espaces/retours à la ligne. Un "do¬shell script"
        // (continuation AppleScript) ou un commentaire inséré entre les mots cassait la contiguïté
        // de "doshellscript" et passait au travers du filtre alors que le comportement exécuté est
        // identique. En ne gardant que les caractères alphanumériques, ce type d'obfuscation par
        // ponctuation ou saut de ligne ne suffit plus à contourner la détection.
        let flat = script.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
        for p in forbiddenPatterns {
            if p.firstMatch(in: flat, range: NSRange(flat.startIndex..., in: flat)) != nil {
                return "Script refusé : commande dangereuse détectée (shell / privilèges admin / clavier via System Events / run-load script / do JavaScript)."
            }
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let e = error {
            return "Erreur AppleScript : \(e)"
        }
        return result?.stringValue ?? "Exécuté avec succès."
    }

    // MARK: - Reminders

    private func addReminder(title: String, notes: String?, dueDate: String?, dueTime: String?) async throws -> String {
        let status = try await eventStore.requestFullAccessToReminders()
        guard status else { return "Accès aux rappels refusé." }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        if let n = notes { reminder.notes = n }
        reminder.calendar = eventStore.defaultCalendarForNewReminders()

        if let dd = dueDate {
            let parts = dd.split(separator: "/").map { Int($0) }
            guard parts.count == 3, let d = parts[0], let m = parts[1], let y = parts[2] else {
                return "Date invalide."
            }
            let comps = dueTime?.split(separator: ":").compactMap { Int($0) } ?? [23, 59]
            var dateComps = DateComponents()
            dateComps.year = y; dateComps.month = m; dateComps.day = d
            dateComps.hour = comps.first; dateComps.minute = comps.count > 1 ? comps[1] : 59
            reminder.dueDateComponents = dateComps
        }

        try eventStore.save(reminder, commit: true)
        return "Rappel \"\(title)\" créé\(notes != nil ? " avec notes" : "")\(dueDate != nil ? " pour le \(dueDate!)" : "")."
    }

    // MARK: - Calendar

    private func addCalendarEvent(args: [String: Any]) async throws -> String {
        let status = try await eventStore.requestFullAccessToEvents()
        guard status else { return "Accès au calendrier refusé." }

        let title = args["title"] as? String ?? ""
        let dateStr = args["date"] as? String ?? ""
        let startTime = args["start_time"] as? String ?? "09:00"
        let duration = args["duration_minutes"] as? Int ?? 60
        let notes = args["notes"] as? String
        let calName = args["calendar"] as? String
        let location = args["location"] as? String

        let dateParts = dateStr.split(separator: "/").compactMap { Int($0) }
        guard dateParts.count >= 3 else { return "Date invalide." }
        let timeParts = startTime.split(separator: ":").compactMap { Int($0) }

        var comps = DateComponents()
        comps.year = dateParts[2]; comps.month = dateParts[1]; comps.day = dateParts[0]
        comps.hour = timeParts.first ?? 9; comps.minute = timeParts.count > 1 ? timeParts[1] : 0
        guard let startDate = Calendar.current.date(from: comps) else { return "Date invalide." }
        let endDate = startDate.addingTimeInterval(TimeInterval(duration * 60))

        let calendars = eventStore.calendars(for: .event)
        let calendar: EKCalendar
        if let name = calName {
            let matches = calendars.filter { $0.title.localizedCaseInsensitiveContains(name) }
            guard let match = matches.first else { return "Calendrier \"\(name)\" introuvable." }
            calendar = match
        } else {
            guard let first = calendars.first(where: { $0.allowsContentModifications }) ?? calendars.first else {
                return "Aucun calendrier disponible."
            }
            calendar = first
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = notes
        event.location = location
        event.calendar = calendar

        try eventStore.save(event, span: .thisEvent)
        return "Événement \"\(title)\" créé le \(dateStr) à \(startTime) (\(duration)min)."
    }

    private func getCalendars() async throws -> String {
        let status = try await eventStore.requestFullAccessToEvents()
        guard status else { return "Accès refusé." }
        let calendars = eventStore.calendars(for: .event)
        return calendars.map { "\($0.title) (\($0.allowsContentModifications ? "écriture" : "lecture seule"))" }.joined(separator: "\n")
    }

    // MARK: - Maps

    private func searchMaps(_ query: String) async throws -> String {
        let lower = query.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let personalLabels = [
            "domicile", "maison", "chez moi", "chezmoi",
            "travail", "bureau", "job", "boulot",
            "ecole", "lycee", "college", "universite", "fac", "school"
        ]
        if personalLabels.contains(where: { lower.contains($0) }) {
            let script = """
            tell application "Contacts"
                launch
                set myCard to my card
                repeat with a in every address of myCard
                    set lbl to ""
                    try
                        set lbl to label of a
                    end try
                    if lbl contains "Home" or lbl contains "Work" or lbl contains "School" then
                        set parts to {street of a, city of a, zip of a, country of a}
                        set filtered to ""
                        repeat with p in parts
                            if p is not missing value and p is not "" then
                                set filtered to filtered & p & ", "
                            end if
                        end repeat
                        if filtered is not "" then
                            return text 1 thru -3 of filtered
                        end if
                    end if
                end repeat
                return ""
            end tell
            """
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let addr = result?.stringValue, !addr.isEmpty {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                NSWorkspace.shared.open(URL(string: "maps://?q=\(encoded)")!)
                return "Adresse trouvée : \"\(addr)\". Passe cette adresse dans le paramètre location."
            }
        }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        NSWorkspace.shared.open(URL(string: "maps://?q=\(encoded)")!)
        return "Plans ouvert avec la recherche \"\(query)\"."
    }

    // MARK: - Shortcuts

    private func runShortcut(_ name: String) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        proc.arguments = ["run", name]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Erreur Shortcut : \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Raccourci \"\(name)\" exécuté." : trimmed
    }

    // MARK: - send_imessage

    private func sendMessage(contact: String, message: String) async throws -> String {
        let handle = try await lookupContactHandle(contact)
        guard !handle.isEmpty else {
            return "Contact \"\(contact)\" introuvable dans l'app Contacts."
        }

        let escapedMessage = message.escapingForAppleScript
        let escapedHandle = handle.escapingForAppleScript

        let script = """
        tell application "Messages"
            -- essayer iMessage d'abord
            try
                set targetService to 1st service whose service type = iMessage
                send "\(escapedMessage)" to buddy "\(escapedHandle)" of targetService
                return "Message envoyé par iMessage."
            on error
                -- fallback SMS
                try
                    set targetService to 1st service whose service type = SMS
                    send "\(escapedMessage)" to buddy "\(escapedHandle)" of targetService
                    return "Message envoyé par SMS (iMessage indisponible)."
                on error
                    return "Impossible d'envoyer le message. Vérifie que le contact a un numéro valide."
                end try
            end try
        end tell
        """
        return try await runAppleScript(script)
    }

    private func lookupContactHandle(_ name: String) async throws -> String {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            let authorized = try await store.requestAccess(for: .contacts)
            guard authorized else { return "" }
        } else if status != .authorized {
            return ""
        }

        let keys: [CNKeyDescriptor] = [
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)

        guard let contact = contacts.first else { return "" }

        if let phone = contact.phoneNumbers.first?.value.stringValue {
            var digits = phone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if digits.hasPrefix("+") { return digits }
            digits = String(digits.drop(while: { $0 == "0" }))
            return "+33\(digits)"
        }
        if let email = contact.emailAddresses.first?.value as String? {
            return email
        }
        return ""
    }

    // MARK: - get_system_info

    private func getSystemInfo() async throws -> String {
        // Disk
        let diskURL = URL(fileURLWithPath: "/")
        let diskValues = try? diskURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let totalGB = (diskValues?.volumeTotalCapacity ?? 1) / 1_000_000_000
        let freeGB = (diskValues?.volumeAvailableCapacity ?? 0) / 1_000_000_000

        // RAM via sysctl
        let ramBytes = try await shell("/usr/sbin/sysctl", ["-n", "hw.memsize"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ramGB = (UInt64(ramBytes) ?? 0) / 1_000_000_000

        // CPU
        let cpu = try await shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Battery
        let battText = try await shell("/usr/sbin/system_profiler", ["SPPowerDataType"])
        let battLine = battText.components(separatedBy: "\n").first { $0.contains("Charge Remaining") }?
            .components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "N/A"
        let chargingLine = battText.components(separatedBy: "\n").first { $0.contains("Charging") }?
            .components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "N/A"

        // Uptime
        let bootStr = try await shell("/usr/sbin/sysctl", ["-n", "kern.boottime"])
        let bootSec = bootStr.components(separatedBy: "sec = ").last?.components(separatedBy: ",").first.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let uptimeDays = bootSec > 0 ? Int(Date().timeIntervalSince1970 - bootSec) / 86400 : 0

        return """
        Mac : \(ProcessInfo.processInfo.hostName)
        CPU : \(cpu)
        RAM : \(ramGB) Go
        Disque : \(freeGB) Go libres / \(totalGB) Go total
        Batterie : \(battLine) (charge : \(chargingLine))
        Uptime : \(uptimeDays) jours
        """
    }

    private func shell(_ exec: String, _ args: [String]) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exec)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        try proc.run()
        proc.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - Clipboard

    private func getClipboard() -> String {
        let pb = NSPasteboard.general
        guard let items = pb.pasteboardItems else { return "Presse-papiers vide." }
        let text = items.compactMap { $0.string(forType: .string) }.joined(separator: "\n")
        return text.isEmpty ? "Presse-papiers vide." : text
    }

    private func setClipboard(_ text: String) -> String {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return "Texte copié dans le presse-papiers."
    }

    // MARK: - take_screenshot

    private func takeScreenshot() async throws -> String {
        let desktop = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let df = DateFormatter()
        df.dateFormat = "'Capture d\u{2019}\u{00E9}cran' yyyy-MM-dd '\u{00E0}' HH.mm.ss"
        let filename = "\(df.string(from: Date())).png"
        let path = desktop.appendingPathComponent(filename).path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", path]
        try proc.run()
        proc.waitUntilExit()
        return "Capture d'écran enregistrée sur le bureau : \(filename)"
    }

    // MARK: - sleep_mac

    private func sleepMac(_ action: String) async throws -> String {
        let lower = action.lowercased()

        switch lower {
        case "sleep", "veille":
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
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                proc.arguments = ["sleepnow"]
                try? proc.run()
            }
            return "Mise en veille."
        case "lock", "verrouiller":
            let lockProc = Process()
            lockProc.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
            lockProc.arguments = ["-suspend"]
            try lockProc.run()
            lockProc.waitUntilExit()
            return "Mac verrouillé."
        case "shutdown", "eteindre":
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
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                proc.arguments = ["shutdown", "now"]
                try? proc.run()
            }
            return "Extinction."
        case "restart", "redemarrer":
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
                let script = """
                tell application "System Events" to restart
                """
                var error: NSDictionary?
                _ = NSAppleScript(source: script)?.executeAndReturnError(&error)
            }
            return "Redémarrage."
        default:
            return "Action inconnue. Utilise sleep, lock, shutdown ou restart."
        }
    }

    // MARK: - file_search

    private func fileSearch(_ query: String) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        proc.arguments = ["-literal", query, "-maxresults", "10"]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()

        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !error.isEmpty { return "Erreur : \(error)" }

        let results = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        if results.isEmpty { return "Aucun fichier trouvé pour \"\(query)\"." }
        if results.count >= 10 { return "Résultats (10 max) :\n" + results.prefix(10).joined(separator: "\n") }
        return "Résultats :\n" + results.joined(separator: "\n")
    }

    // MARK: - get_upcoming_events

    private func getUpcomingEvents(days: Int) async throws -> String {
        let status = try await eventStore.requestFullAccessToEvents()
        guard status else { return "Accès au calendrier refusé." }

        let startDate = Date()
        guard let endDate = Calendar.current.date(byAdding: .day, value: days, to: startDate) else {
            return "Erreur de date."
        }

        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        if events.isEmpty { return "Aucun événement dans les \(days) prochains jours." }

        let df = DateFormatter()
        df.dateFormat = "dd/MM HH:mm"

        return events.prefix(20).map { event in
            let start = df.string(from: event.startDate)
            let location = event.location ?? ""
            return "\(start) - \(event.title ?? "")\(location.isEmpty ? "" : " @ \(location)")"
        }.joined(separator: "\n")
    }

    // MARK: - list_reminders

    private func listReminders(list: String?) async throws -> String {
        let status = try await eventStore.requestFullAccessToReminders()
        guard status else { return "Accès aux rappels refusé." }

        let predicate: NSPredicate
        if let listName = list {
            let calendars = eventStore.calendars(for: .reminder)
            guard let cal = calendars.first(where: { $0.title.localizedCaseInsensitiveContains(listName) }) else {
                return "Liste \"\(listName)\" introuvable."
            }
            predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [cal])
        } else {
            let calendars = eventStore.calendars(for: .reminder)
            predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        }

        let reminders = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[EKReminder], Error>) in
            let _ = eventStore.fetchReminders(matching: predicate) { items in
                cont.resume(returning: items ?? [])
            }
        }

        if reminders.isEmpty { return "Aucun rappel en attente." }

        let df = DateFormatter()
        df.dateFormat = "dd/MM/yyyy"

        return reminders.prefix(20).map { reminder in
            let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }.map { df.string(from: $0) } ?? ""
            return "\(reminder.title ?? "")\(due.isEmpty ? "" : " (pour le \(due))")"
        }.joined(separator: "\n")
    }

    // MARK: - get_weather

    /// Open-Meteo plutôt que search_web : sans clé API, JSON stable, pas de scraping HTML fragile
    /// (contrairement à DuckDuckGo Lite dont le parsing casse au moindre changement de markup).
    private func getWeather(city: String) async throws -> String {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Aucune ville fournie." }

        guard let encodedCity = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let geoURL = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(encodedCity)&count=1&language=fr&format=json")
        else { return "Erreur d'encodage du nom de ville." }

        guard let geoData = try? await URLSession.shared.data(for: {
            var r = URLRequest(url: geoURL); r.timeoutInterval = 10; return r
        }()).0,
              let geoJSON = try? JSONSerialization.jsonObject(with: geoData) as? [String: Any],
              let results = geoJSON["results"] as? [[String: Any]],
              let first = results.first,
              let lat = first["latitude"] as? Double,
              let lon = first["longitude"] as? Double
        else {
            return "Ville \"\(trimmed)\" introuvable. Vérifie l'orthographe ou précise le pays."
        }
        let resolvedName = first["name"] as? String ?? trimmed
        let country = first["country"] as? String ?? ""

        guard let forecastURL = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m&daily=temperature_2m_max,temperature_2m_min,weather_code,precipitation_sum,wind_speed_10m_max&timezone=auto") else {
            return "Erreur de construction de l'URL météo."
        }
        guard let (data, response) = try? await URLSession.shared.data(for: {
            var r = URLRequest(url: forecastURL); r.timeoutInterval = 10; return r
        }()),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any]
        else {
            return "Service météo indisponible pour \(resolvedName) en ce moment."
        }

        let temp = current["temperature_2m"] as? Double ?? 0
        let feelsLike = current["apparent_temperature"] as? Double ?? temp
        let humidity = current["relative_humidity_2m"] as? Double ?? 0
        let wind = current["wind_speed_10m"] as? Double ?? 0
        let code = current["weather_code"] as? Int ?? -1

        let condition = Self.weatherCodeDescriptions[code] ?? "conditions inconnues"

        var result = "Météo à \(resolvedName)\(country.isEmpty ? "" : ", \(country)") : actuellement \(condition), \(String(format: "%.0f", temp))°C (ressenti \(String(format: "%.0f", feelsLike))°C), humidité \(String(format: "%.0f", humidity))%, vent \(String(format: "%.0f", wind)) km/h."

        if let daily = json["daily"] as? [String: Any],
           let dates = daily["time"] as? [String],
           let maxTemps = daily["temperature_2m_max"] as? [Double],
           let minTemps = daily["temperature_2m_min"] as? [Double],
           let weatherCodes = daily["weather_code"] as? [Int],
           let precip = daily["precipitation_sum"] as? [Double],
           let windMax = daily["wind_speed_10m_max"] as? [Double] {

            for i in 0..<min(dates.count, 3) where i > 0 {
                let dayName = i == 1 ? "Demain" : "Le \(dates[i])"
                let dayCode = weatherCodes.indices.contains(i) ? weatherCodes[i] : -1
                let dayCondition = Self.weatherCodeDescriptions[dayCode] ?? "conditions inconnues"
                let dayPrecip = precip.indices.contains(i) ? precip[i] : 0
                let dayWind = windMax.indices.contains(i) ? windMax[i] : 0
                result += " | \(dayName) : \(dayCondition), \(String(format: "%.0f", minTemps[i]))°C ~ \(String(format: "%.0f", maxTemps[i]))°C, précip. \(String(format: "%.0f", dayPrecip))mm, vent \(String(format: "%.0f", dayWind)) km/h."
            }
        }

        return result
    }

    private static let weatherCodeDescriptions: [Int: String] = [
        0: "ciel dégagé", 1: "plutôt dégagé", 2: "partiellement nuageux", 3: "couvert",
        45: "brouillard", 48: "brouillard givrant",
        51: "bruine légère", 53: "bruine modérée", 55: "bruine dense",
        61: "pluie légère", 63: "pluie modérée", 65: "pluie forte",
        71: "neige légère", 73: "neige modérée", 75: "neige forte",
        80: "averses légères", 81: "averses modérées", 82: "averses violentes",
        95: "orage", 96: "orage avec grêle légère", 99: "orage avec grêle forte",
    ]

    private func readURL(_ urlString: String) async throws -> String {
        let normalized = urlString.hasPrefix("http") ? urlString : "https://\(urlString)"
        guard let url = URL(string: normalized) else { return "URL invalide : \(urlString)." }
        guard let html = await fetchPage(url, timeout: 12) else {
            return "Impossible de récupérer le contenu de \(urlString) (page inaccessible ou timeout)."
        }
        let text = html.htmlToText(maxLength: 4000)
        return text.count > 100 ? text : "Contenu de la page insuffisant ou vide."
    }

    // MARK: - run_routine

    private func runRoutine(_ name: String) async throws -> String {
        switch name.lowercased() {
        case "morning", "matin":
            // Appels directs aux implémentations plutôt que via execute() : évite de repasser par le
            // dispatcher pour un enchaînement interne connu, et garde des erreurs isolées par étape
            // (un tool en échec dans la routine ne doit pas faire échouer les deux autres).
            var parts: [String] = []

            if let events = try? await getUpcomingEvents(days: 1), !events.isEmpty {
                parts.append("Aujourd'hui :\n\(events)")
            } else {
                parts.append("Aucun événement aujourd'hui.")
            }

            if let sysInfo = try? await getSystemInfo() {
                parts.append(sysInfo)
            }

            return parts.joined(separator: "\n\n")
        default:
            return "Routine \"\(name)\" inconnue. Routines disponibles : morning."
        }
    }

    // MARK: - remember_fact

    private func rememberFact(key: String, value: String) async -> String {
        guard !key.isEmpty, !value.isEmpty else { return "Erreur : clé et valeur requis." }
        try? await DatabaseService.shared.upsertFact(key: key, value: value)
        return "Fait mémorisé : \(key) = \(value)"
    }
}

/// Find bundle path by app name (common locations)
private func bundlePath(for appName: String) -> String? {
    let paths = [
        "/Applications/\(appName).app",
        "/Applications/Utilities/\(appName).app",
        "/System/Applications/\(appName).app",
        "/System/Applications/Utilities/\(appName).app",
        "\(NSHomeDirectory())/Applications/\(appName).app"
    ]
    return paths.first { FileManager.default.fileExists(atPath: $0) }
}

/// Fallback: lookup by bundle identifier
private func appStoreBundlePath(for appName: String) -> String? {
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
        "Home": "com.apple.home",
    ]
    guard let bid = bundleIDs[appName] ?? bundleIDs[appName.lowercased()] else { return nil }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return nil }
    return url.path
}
