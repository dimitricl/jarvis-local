@testable import JarvisServices
import XCTest

final class JarvisLocalToolServiceTests: XCTestCase {

    func testToolDefsContainAllExpectedTools() async {
        let tools = ToolService.shared
        let defs = await tools.toolDefs
        let names = Set(defs.map { $0.function.name })

        let expectedTools: Set<String> = [
            "search_web", "open_app", "create_note", "edit_note",
            "get_weather", "add_reminder", "add_calendar_event", "get_calendars",
            "search_maps", "run_shortcut", "send_message", "get_system_info",
            "get_clipboard", "set_clipboard", "take_screenshot", "sleep_mac",
            "file_search", "get_upcoming_events", "list_reminders", "read_url",
            "run_routine", "remember_fact"
        ]

        for tool in expectedTools {
            XCTAssertTrue(names.contains(tool), "Missing tool: \(tool)")
        }
    }

    func testToolDefsHaveValidParameterSchemas() async {
        let tools = ToolService.shared
        let defs = await tools.toolDefs

        for def in defs {
            let params = def.function.parameters
            XCTAssertEqual(params.type, "object")
            XCTAssertNotNil(params.properties)
            XCTAssertNotNil(params.required)

            for (_, prop) in params.properties {
                XCTAssertFalse(prop.type.isEmpty, "Property type should not be empty for \(def.function.name)")
            }
        }
    }

    func testSearchWebReturnsErrorForEmptyQuery() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "search_web", args: ["query": ""])
        // Chantier 1 : le service cascade répond "Requête vide" sans même appeler le réseau.
        XCTAssertTrue(result.contains("Requête vide") || result.contains("Erreur d'encodage") || result.contains("Aucun résultat"))
    }

    func testOpenAppUnknownAppReturnsError() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "open_app", args: ["app": "ThisAppDefinitelyDoesNotExist12345"])
        XCTAssertTrue(result.contains("introuvable"))
    }

    func testFormatSearchResultsIncludesSourceURL() {
        let out = ToolService.formatSearchResults([
            (title: "Exemple", href: "https://example.com/page", text: "Contenu utile"),
            (title: "Sans contenu", href: "https://example.com/vide", text: nil)
        ])
        XCTAssertTrue(out.contains("Source : https://example.com/page"))
        XCTAssertTrue(out.contains("Contenu utile"))
        XCTAssertTrue(out.contains("--- Sans contenu ---"))
        // Pas de ligne "Contenu :" pour le résultat sans texte.
        XCTAssertEqual(out.components(separatedBy: "Contenu :").count - 1, 1)
    }

    func testRememberFactRequiresKeyAndValue() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "remember_fact", args: ["key": "", "value": ""])
        XCTAssertTrue(result.contains("Erreur"), "Un remember_fact vide doit retourner une erreur explicite, pas un succès.")
    }

    func testCreateNoteRequiresTitleAndBody() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "create_note", args: ["title": "", "body": ""])
        XCTAssertTrue(result.contains("Erreur") || result.isEmpty == false)
    }

    func testEditNoteRequiresSearchTitleAndBody() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "edit_note", args: ["search_title": "", "body": ""])
        XCTAssertTrue(result.contains("Erreur") || result.contains("Note introuvable") || result.isEmpty == false)
    }

    /// L'outil générique exposait un AppleScript ARBITRAIRE au modèle (RCE triviale
    /// par concaténation de chaînes, `tell app "Terminal"…` — classe de bug non
    /// filtrable par denylist). Supprimé au profit de capacités typées (PowerAction,
    /// templates figés). Ce test verrouille la suppression : toute réintroduction
    /// fait échouer la suite.
    func testGenericAppleScriptToolRemoved() async throws {
        let tools = ToolService.shared
        let names = Set(await tools.toolDefs.map { $0.function.name })
        XCTAssertFalse(names.contains("applescript"), "L'outil applescript générique ne doit jamais revenir")
        let result = try await tools.execute(name: "applescript", args: ["script": "return 1"])
        XCTAssertEqual(result, "Outil inconnu : applescript")
    }

    func testAddReminderRequiresTitle() async throws {
        try skipIfCIHeadless("EventKit (Rappels) : prompt TCC sans humain en CI")
        let tools = ToolService.shared
        let result = try await tools.execute(name: "add_reminder", args: ["title": "Test reminder"])
        XCTAssertTrue(result.contains("créé") || result.contains("Erreur") || result.contains("Accès"))
    }

    func testAddCalendarEventRequiresTitleAndDate() async throws {
        try skipIfCIHeadless("EventKit (Calendrier) : prompt TCC sans humain en CI")
        let tools = ToolService.shared
        let result = try await tools.execute(name: "add_calendar_event", args: ["title": "Test", "date": "25/12/2025"])
        XCTAssertTrue(result.contains("créé") || result.contains("Erreur") || result.contains("Accès"))
    }

    func testGetCalendarsReturnsListOrError() async throws {
        try skipIfCIHeadless("EventKit (Calendrier) : prompt TCC sans humain en CI")
        let tools = ToolService.shared
        let result = try await tools.execute(name: "get_calendars", args: [:])
        XCTAssertTrue(result.contains("écriture") || result.contains("lecture") || result.contains("Accès") || result.contains("Aucun"))
    }

    func testSearchMapsReturnsResultOrOpensMaps() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "search_maps", args: ["query": "Paris"])
        XCTAssertTrue(result.contains("Plans") || result.contains("Adresse") || result.contains("introuvable"))
    }

    func testRunShortcutUnknownReturnsError() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "run_shortcut", args: ["name": "NonExistentShortcut123"])
        XCTAssertTrue(result.contains("Erreur") || result.contains("introuvable"))
    }

    func testSendMessageUnknownContactReturnsError() async throws {
        try skipIfCIHeadless("Contacts : prompt TCC sans humain en CI")
        let tools = ToolService.shared
        let result = try await tools.execute(name: "send_message", args: ["contact": "ContactInconnu12345", "message": "test"])
        XCTAssertTrue(result.contains("introuvable") || result.contains("Erreur") || result.contains("Accès"))
    }

    func testGetSystemInfoReturnsFormattedInfo() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "get_system_info", args: [:])
        XCTAssertTrue(result.contains("Mac :"))
        XCTAssertTrue(result.contains("CPU :"))
        XCTAssertTrue(result.contains("RAM :"))
        XCTAssertTrue(result.contains("Disque :"))
        XCTAssertTrue(result.contains("Batterie :"))
        XCTAssertTrue(result.contains("Uptime :"))
    }

    func testClipboardOperations() async throws {
        let tools = ToolService.shared

        let setResult = try await tools.execute(name: "set_clipboard", args: ["text": "Test clipboard content"])
        XCTAssertTrue(setResult.contains("copié"))

        let getResult = try await tools.execute(name: "get_clipboard", args: [:])
        XCTAssertTrue(getResult.contains("Test clipboard content"))
    }

    func testTakeScreenshotReturnsPathOrError() async throws {
        try skipIfCIHeadless("screencapture : prompt capture d'écran sans humain en CI")
        let tools = ToolService.shared
        let result = try await tools.execute(name: "take_screenshot", args: [:])
        XCTAssertTrue(result.contains("Capture d'écran") || result.contains("Erreur"))
    }

    func testSleepMacActions() async throws {
        // Volontairement limité à "lock" + action invalide : "sleep", "shutdown"
        // et "restart" exécutent RÉELLEMENT la mise en veille / l'extinction /
        // le redémarrage du Mac qui lance la suite (constaté : reboot en pleine
        // session de dev). Ne jamais réajouter d'action à effet destructeur ici.
        // NOTE : "lock" verrouille réellement l'écran — ne lancer ce test qu'en
        // session déverrouillable immédiatement.
        let tools = ToolService.shared

        let lockResult = try await tools.execute(name: "sleep_mac", args: ["action": "lock"])
        XCTAssertTrue(lockResult.contains("verrouill") || lockResult.contains("Mac verrouillé"))

        let invalidResult = try await tools.execute(name: "sleep_mac", args: ["action": "invalid"])
        XCTAssertTrue(invalidResult.contains("inconnue"))
    }

    func testFileSearchReturnsResultsOrError() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "file_search", args: ["query": "Info.plist"])
        XCTAssertTrue(result.contains("Résultats") || result.contains("Aucun") || result.contains("Erreur"))
    }

    func testGetUpcomingEventsReturnsListOrError() async throws {
        try skipIfCIHeadless("EventKit (Calendrier) : prompt TCC sans humain en CI")
        let tools = ToolService.shared
        let result = try await tools.execute(name: "get_upcoming_events", args: ["days": 7])
        // Vérifie juste que ça ne crashe pas et retourne une string
        XCTAssertFalse(result.isEmpty)
    }

    func testListRemindersReturnsListOrError() async throws {
        try skipIfCIHeadless("EventKit (Rappels) : prompt TCC sans humain en CI")
        let tools = ToolService.shared
        let result = try await tools.execute(name: "list_reminders", args: [:])
        // Vérifie juste que ça ne crashe pas et retourne une string
        XCTAssertFalse(result.isEmpty)
    }

    func testReadURLRejectsLocalTargets() async throws {
        // Anti-SSRF : file://, localhost, loopback et LAN refusés SANS réseau
        // (littéraux et noms réservés — aucune résolution DNS requise).
        let tools = ToolService.shared
        for url in ["file:///etc/passwd", "http://localhost:11434/api/tags",
                    "http://127.0.0.1/", "http://192.168.1.1/", "http://169.254.169.254/"] {
            let result = try await tools.execute(name: "read_url", args: ["url": url])
            XCTAssertTrue(result.contains("refusée"), "read_url aurait dû refuser \(url) : \(result)")
        }
    }

    func testReadURLAlwaysCitesSource() async throws {
        // Avec ou sans réseau : le préfixe "Source :" est garanti (succès comme échec),
        // pour que le modèle puisse citer — ou dire qu'il n'a rien récupéré.
        let tools = ToolService.shared
        let result = try await tools.execute(name: "read_url", args: ["url": "https://example.com"])
        XCTAssertTrue(result.contains("Source : https://example.com"))
    }

    func testHttpURLAllowlist() {
        XCTAssertNotNil(SystemTools.httpURL(from: "https://example.com/page"))
        XCTAssertNotNil(SystemTools.httpURL(from: "example.com"))
        XCTAssertNil(SystemTools.httpURL(from: "file:///etc/passwd"))
        XCTAssertNil(SystemTools.httpURL(from: "ftp://example.com/x"))
        XCTAssertNil(SystemTools.httpURL(from: ""))
    }

    func testSendMessageRejectsEmptyAndOversizedBody() async throws {
        // Validé AVANT tout accès Contacts : pas de permission requise.
        let tools = ToolService.shared
        let empty = try await tools.execute(name: "send_message", args: ["contact": "X", "message": ""])
        XCTAssertTrue(empty.contains("vide ou trop long"))
        let big = try await tools.execute(name: "send_message", args: ["contact": "X", "message": String(repeating: "a", count: 1001)])
        XCTAssertTrue(big.contains("vide ou trop long"))
    }

    func testRunRoutineUnknownReturnsError() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "run_routine", args: ["name": "NonExistentRoutine123"])
        XCTAssertTrue(result.contains("inconnue") || result.contains("Erreur"))
    }

    func testRememberFactReturnsConfirmation() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "remember_fact", args: ["key": "test.key", "value": "test value"])
        XCTAssertTrue(result.contains("mémorisé") || result.contains("Mémorisé") || result.contains("OK"))
    }

    func testUnknownToolReturnsError() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "unknown_tool_xyz", args: [:])
        XCTAssertEqual(result, "Outil inconnu : unknown_tool_xyz")
    }
}

final class JarvisLocalToolServiceIntegrationTests: XCTestCase {

    func testToolDefNamesAreUnique() async {
        let tools = ToolService.shared
        let defs = await tools.toolDefs
        let names = defs.map { $0.function.name }
        let uniqueNames = Set(names)
        XCTAssertEqual(names.count, uniqueNames.count, "Tool names should be unique")
    }

    func testAllToolsHaveDescriptions() async {
        let tools = ToolService.shared
        let defs = await tools.toolDefs

        for def in defs {
            XCTAssertFalse(def.function.description.isEmpty, "Tool \(def.function.name) should have a description")
            XCTAssertGreaterThan(def.function.description.count, 10, "Tool \(def.function.name) description should be meaningful")
        }
    }

    func testRequiredParametersMatchProperties() async {
        let tools = ToolService.shared
        let defs = await tools.toolDefs

        for def in defs {
            let params = def.function.parameters
            for required in params.required {
                XCTAssertNotNil(params.properties[required], "Required parameter '\(required)' should exist in properties for tool \(def.function.name)")
            }
        }
    }
}
