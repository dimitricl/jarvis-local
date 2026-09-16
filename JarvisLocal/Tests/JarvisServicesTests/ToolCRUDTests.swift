@testable import JarvisServices
import XCTest

/// Tâche 2 — CRUD Rappels/Calendrier/Notes : ToolDefs exposés au modèle avec le
/// même format que add_reminder/list_reminders (required ⊂ properties), et
/// garde-fous "jamais d'action sur identifiant deviné" (id introuvable =
/// message qui renvoie vers le listing, pas d'approximation).
/// Les tests qui touchent EventKit/Notes s'auto-skippent en CI headless
/// (pas de TCC sans humain) ; les validations strictes restent couvertes
/// en CI via ToolStrictArgsTests.
final class ToolCRUDTests: XCTestCase {
    func testNewToolDefsPresentWithValidSchemas() async {
        let names = Set(await ToolService.shared.toolDefs.map { $0.function.name })
        for tool in ["complete_reminder", "delete_reminder", "edit_calendar_event",
                     "delete_calendar_event", "search_notes", "read_note",
                     "list_directory", "read_file"] {
            XCTAssertTrue(names.contains(tool), "ToolDef manquant : \(tool)")
        }
        // Même format que les existants : required ⊂ properties.
        for def in await ToolService.shared.toolDefs {
            for req in def.function.parameters.required {
                XCTAssertNotNil(def.function.parameters.properties[req],
                                 "required '\(req)' absent de properties pour \(def.function.name)")
            }
        }
    }

    func testNewToolDefsRequireIdentifiers() async {
        let defs = await ToolService.shared.toolDefs
        func req(_ name: String) -> [String] {
            defs.first(where: { $0.function.name == name })?.function.parameters.required ?? []
        }
        XCTAssertTrue(req("complete_reminder").contains("id"))
        XCTAssertTrue(req("delete_reminder").contains("id"))
        XCTAssertTrue(req("edit_calendar_event").contains("id"))
        XCTAssertTrue(req("delete_calendar_event").contains("id"))
        XCTAssertTrue(req("search_notes").contains("query"))
        XCTAssertTrue(req("read_note").contains("id"))
        XCTAssertTrue(req("list_directory").contains("path"))
        XCTAssertTrue(req("read_file").contains("path"))
    }

    func testCompleteReminderUnknownIdPointsToListing() async throws {
        try skipIfCIHeadless("EventKit (Rappels) : prompt TCC sans humain en CI")
        let r = try await ToolService.shared.execute(name: "complete_reminder", args: ["id": "id-inexistant-12345"])
        XCTAssertTrue(r.contains("introuvable"))
        XCTAssertTrue(r.contains("list_reminders"))
    }

    func testDeleteReminderUnknownIdPointsToListing() async throws {
        try skipIfCIHeadless("EventKit (Rappels) : prompt TCC sans humain en CI")
        let r = try await ToolService.shared.execute(name: "delete_reminder", args: ["id": "id-inexistant-12345"])
        XCTAssertTrue(r.contains("introuvable"))
        XCTAssertTrue(r.contains("list_reminders"))
    }

    func testEditCalendarEventUnknownIdPointsToListing() async throws {
        try skipIfCIHeadless("EventKit (Calendrier) : prompt TCC sans humain en CI")
        let r = try await ToolService.shared.execute(
            name: "edit_calendar_event", args: ["id": "id-inexistant-12345", "title": "x"])
        XCTAssertTrue(r.contains("introuvable"))
        XCTAssertTrue(r.contains("get_upcoming_events"))
    }

    func testDeleteCalendarEventUnknownIdPointsToListing() async throws {
        try skipIfCIHeadless("EventKit (Calendrier) : prompt TCC sans humain en CI")
        let r = try await ToolService.shared.execute(name: "delete_calendar_event", args: ["id": "id-inexistant-12345"])
        XCTAssertTrue(r.contains("introuvable"))
        XCTAssertTrue(r.contains("get_upcoming_events"))
    }

    func testSearchNotesEmptyResultMessage() async throws {
        try skipIfCIHeadless("Apple Notes : pas d'app Notes en CI headless")
        // Requête improbable : attend un message "aucune note", pas un crash.
        let r = try await ToolService.shared.execute(name: "search_notes", args: ["query": "zzz-improbable-12345"])
        XCTAssertTrue(r.contains("Aucune note") || r.contains("[id:"))
    }
}
