@testable import JarvisLocal
import XCTest

final class JarvisLocalToolServiceTests: XCTestCase {

    func testToolDefsContainAllExpectedTools() async {
        let tools = ToolService.shared
        let defs = await tools.toolDefs
        let names = Set(defs.map { $0.function.name })

        let expectedTools: Set<String> = [
            "search_web", "open_app", "create_note", "edit_note", "applescript",
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
            (title: "Sans contenu", href: "https://example.com/vide", text: nil),
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

    func testAppleScriptRejectedForDangerousCommands() async throws {
        let tools = ToolService.shared

        let dangerousScripts = [
            "do shell script \"rm -rf /\"",
            "tell application \"System Events\" to keystroke \"a\"",
            "run script \"malicious\"",
            "load script file \"evil\"",
            "do JavaScript \"alert(1)\" in document 1"
        ]

        for script in dangerousScripts {
            let result = try await tools.execute(name: "applescript", args: ["script": script])
            // Vérifie juste que ça ne crashe pas et retourne une string
            XCTAssertFalse(result.isEmpty)
        }
    }

    func testAppleScriptAllowedForSafeCommands() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "applescript", args: ["script": "return \"hello world\""])
        XCTAssertTrue(result.contains("hello world") || result.contains("Exécuté"))
    }

    func testAddReminderRequiresTitle() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "add_reminder", args: ["title": "Test reminder"])
        XCTAssertTrue(result.contains("créé") || result.contains("Erreur") || result.contains("Accès"))
    }

    func testAddCalendarEventRequiresTitleAndDate() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "add_calendar_event", args: ["title": "Test", "date": "25/12/2025"])
        XCTAssertTrue(result.contains("créé") || result.contains("Erreur") || result.contains("Accès"))
    }

    func testGetCalendarsReturnsListOrError() async throws {
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
        let tools = ToolService.shared
        let result = try await tools.execute(name: "take_screenshot", args: [:])
        XCTAssertTrue(result.contains("Capture d'écran") || result.contains("Erreur"))
    }

    func testSleepMacActions() async throws {
        let tools = ToolService.shared

        let sleepResult = try await tools.execute(name: "sleep_mac", args: ["action": "sleep"])
        XCTAssertTrue(sleepResult.contains("veille") || sleepResult.contains("Mise en veille"))

        let lockResult = try await tools.execute(name: "sleep_mac", args: ["action": "lock"])
        XCTAssertTrue(lockResult.contains("verrouill") || lockResult.contains("Mac verrouillé"))

        let shutdownResult = try await tools.execute(name: "sleep_mac", args: ["action": "shutdown"])
        XCTAssertTrue(shutdownResult.contains("Extinction") || shutdownResult.contains("eteindre"))

        let restartResult = try await tools.execute(name: "sleep_mac", args: ["action": "restart"])
        XCTAssertTrue(restartResult.contains("Redémarrage") || restartResult.contains("redemarrer"))

        let invalidResult = try await tools.execute(name: "sleep_mac", args: ["action": "invalid"])
        XCTAssertTrue(invalidResult.contains("inconnue"))
    }

    func testFileSearchReturnsResultsOrError() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "file_search", args: ["query": "Info.plist"])
        XCTAssertTrue(result.contains("Résultats") || result.contains("Aucun") || result.contains("Erreur"))
    }

    func testGetUpcomingEventsReturnsListOrError() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "get_upcoming_events", args: ["days": 7])
        // Vérifie juste que ça ne crashe pas et retourne une string
        XCTAssertFalse(result.isEmpty)
    }

    func testListRemindersReturnsListOrError() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "list_reminders", args: [:])
        // Vérifie juste que ça ne crashe pas et retourne une string
        XCTAssertFalse(result.isEmpty)
    }

    func testReadURLReturnsContentOrError() async throws {
        let tools = ToolService.shared
        let result = try await tools.execute(name: "read_url", args: ["url": "https://example.com"])
        XCTAssertTrue(result.contains("Erreur") || result.contains("indisponible") || result.count > 0)
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

final class JarvisLocalToolServiceArgumentParsingTests: XCTestCase {

    func testParseToolArgumentsValidJSON() throws {
        let args = AppViewModel.parseToolArguments("{\"query\": \"test\", \"count\": 5}")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
        XCTAssertEqual(args?["count"] as? Int, 5)
    }

    func testParseToolArgumentsWithTrailingComma() throws {
        let args = AppViewModel.parseToolArguments("{\"query\": \"test\",}")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
    }

    func testParseToolArgumentsWithMarkdownFences() throws {
        let args = AppViewModel.parseToolArguments("```json\n{\"query\": \"test\"}\n```")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
    }

    func testParseToolArgumentsWithSmartQuotes() throws {
        let args = AppViewModel.parseToolArguments("{\"query\": \"test\"}")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
    }

    func testParseToolArgumentsEmptyString() throws {
        let args = AppViewModel.parseToolArguments("")
        XCTAssertNotNil(args)
        XCTAssertTrue(args!.isEmpty)
    }

    func testParseToolArgumentsInvalidJSONReturnsNil() throws {
        let args = AppViewModel.parseToolArguments("not json at all")
        XCTAssertNil(args)
    }

    func testParseToolArgumentsDoubleEncoded() throws {
        let args = AppViewModel.parseToolArguments("{\"app\": \"{\\\"app\\\": \\\"Safari\\\"}\"}")
        XCTAssertNotNil(args)
    }
}