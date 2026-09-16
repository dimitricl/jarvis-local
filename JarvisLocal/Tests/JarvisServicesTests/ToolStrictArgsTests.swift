@testable import JarvisServices
import XCTest

/// Tâche 1 — extraction stricte du dispatcher : un argument absent ou mal typé
/// ne vaut JAMAIS une valeur par défaut silencieuse ("", 7…) — le modèle reçoit
/// "Paramètre 'x' manquant ou de type invalide pour l'outil 'y'" et corrige.
/// Chaque case du switch est couverte (manquant + mal typé), pas seulement les
/// nouveaux outils. Tous ces chemins d'erreur répondent AVANT toute permission
/// système (TCC), réseau ou AppleScript : verts en CI headless.
final class ToolStrictArgsTests: XCTestCase {
    private func strict(_ key: String, tool: String) -> String {
        "Paramètre '\(key)' manquant ou de type invalide pour l'outil '\(tool)'"
    }

    private func missing(_ tool: String, key: String) async throws -> String {
        try await ToolService.shared.execute(name: tool, args: [:])
    }

    // MARK: - search_web / search_maps / file_search

    func testSearchWebMissingQuery() async throws {
        let got_search_web_query = try await missing("search_web", key: "query")
        XCTAssertEqual(got_search_web_query, strict("query", tool: "search_web"))
    }

    func testSearchWebWrongTypeQuery() async throws {
        let r = try await ToolService.shared.execute(name: "search_web", args: ["query": 42])
        XCTAssertEqual(r, strict("query", tool: "search_web"))
    }

    func testSearchMapsMissingQuery() async throws {
        let got_search_maps_query = try await missing("search_maps", key: "query")
        XCTAssertEqual(got_search_maps_query, strict("query", tool: "search_maps"))
    }

    func testSearchMapsWrongTypeQuery() async throws {
        let r = try await ToolService.shared.execute(name: "search_maps", args: ["query": ["Paris"]])
        XCTAssertEqual(r, strict("query", tool: "search_maps"))
    }

    func testFileSearchMissingQuery() async throws {
        let got_file_search_query = try await missing("file_search", key: "query")
        XCTAssertEqual(got_file_search_query, strict("query", tool: "file_search"))
    }

    func testFileSearchWrongTypeQuery() async throws {
        let r = try await ToolService.shared.execute(name: "file_search", args: ["query": 3.5])
        XCTAssertEqual(r, strict("query", tool: "file_search"))
    }

    // MARK: - open_app

    func testOpenAppMissingApp() async throws {
        let got_open_app_app = try await missing("open_app", key: "app")
        XCTAssertEqual(got_open_app_app, strict("app", tool: "open_app"))
    }

    func testOpenAppWrongTypeApp() async throws {
        let r = try await ToolService.shared.execute(name: "open_app", args: ["app": 42])
        XCTAssertEqual(r, strict("app", tool: "open_app"))
    }

    func testOpenAppWrongTypeURL() async throws {
        let r = try await ToolService.shared.execute(name: "open_app", args: ["app": "Safari", "url": 42])
        XCTAssertEqual(r, strict("url", tool: "open_app"))
    }

    // MARK: - create_note / edit_note

    func testCreateNoteMissingTitle() async throws {
        let r = try await ToolService.shared.execute(name: "create_note", args: ["body": "x"])
        XCTAssertEqual(r, strict("title", tool: "create_note"))
    }

    func testCreateNoteMissingBody() async throws {
        let r = try await ToolService.shared.execute(name: "create_note", args: ["title": "x"])
        XCTAssertEqual(r, strict("body", tool: "create_note"))
    }

    func testCreateNoteWrongTypes() async throws {
        let r = try await ToolService.shared.execute(name: "create_note", args: ["title": 1, "body": "x"])
        XCTAssertEqual(r, strict("title", tool: "create_note"))
        let r2 = try await ToolService.shared.execute(name: "create_note", args: ["title": "x", "body": true])
        XCTAssertEqual(r2, strict("body", tool: "create_note"))
    }

    func testEditNoteMissingSearchTitle() async throws {
        let r = try await ToolService.shared.execute(name: "edit_note", args: ["body": "x"])
        XCTAssertEqual(r, strict("search_title", tool: "edit_note"))
    }

    func testEditNoteMissingBody() async throws {
        let r = try await ToolService.shared.execute(name: "edit_note", args: ["search_title": "x"])
        XCTAssertEqual(r, strict("body", tool: "edit_note"))
    }

    func testEditNoteWrongTypeNewTitle() async throws {
        let r = try await ToolService.shared.execute(
            name: "edit_note", args: ["search_title": "x", "body": "y", "new_title": 42])
        XCTAssertEqual(r, strict("new_title", tool: "edit_note"))
    }

    // MARK: - add_reminder / list_reminders

    func testAddReminderMissingTitle() async throws {
        let got_add_reminder_title = try await missing("add_reminder", key: "title")
        XCTAssertEqual(got_add_reminder_title, strict("title", tool: "add_reminder"))
    }

    func testAddReminderWrongTypes() async throws {
        let r = try await ToolService.shared.execute(name: "add_reminder", args: ["title": 42])
        XCTAssertEqual(r, strict("title", tool: "add_reminder"))
        let r2 = try await ToolService.shared.execute(
            name: "add_reminder", args: ["title": "x", "due_date": 20250101])
        XCTAssertEqual(r2, strict("due_date", tool: "add_reminder"))
    }

    func testListRemindersWrongTypeList() async throws {
        let r = try await ToolService.shared.execute(name: "list_reminders", args: ["list": 42])
        XCTAssertEqual(r, strict("list", tool: "list_reminders"))
    }

    // MARK: - add_calendar_event / get_upcoming_events

    func testAddCalendarEventMissingTitle() async throws {
        let r = try await ToolService.shared.execute(name: "add_calendar_event", args: ["date": "25/12/2025"])
        XCTAssertEqual(r, strict("title", tool: "add_calendar_event"))
    }

    func testAddCalendarEventMissingDate() async throws {
        let r = try await ToolService.shared.execute(name: "add_calendar_event", args: ["title": "x"])
        XCTAssertEqual(r, strict("date", tool: "add_calendar_event"))
    }

    func testAddCalendarEventWrongTypes() async throws {
        let r = try await ToolService.shared.execute(
            name: "add_calendar_event", args: ["title": 1, "date": "25/12/2025"])
        XCTAssertEqual(r, strict("title", tool: "add_calendar_event"))
        let r2 = try await ToolService.shared.execute(
            name: "add_calendar_event", args: ["title": "x", "date": "25/12/2025", "duration_minutes": "long"])
        XCTAssertEqual(r2, strict("duration_minutes", tool: "add_calendar_event"))
    }

    func testGetUpcomingEventsWrongTypeDays() async throws {
        let r = try await ToolService.shared.execute(name: "get_upcoming_events", args: ["days": "sept"])
        XCTAssertEqual(r, strict("days", tool: "get_upcoming_events"))
    }

    func testGetUpcomingEventsAcceptsDoubleDays() async throws {
        // Les nombres JSON arrivent en Double : accepté, pas d'erreur stricte.
        // (En CI headless on skipe l'accès EventKit, mais le parsing ne doit pas refuser.)
        try skipIfCIHeadless("EventKit : prompt TCC sans humain en CI")
        let r = try await ToolService.shared.execute(name: "get_upcoming_events", args: ["days": 7.0])
        XCTAssertFalse(r.contains("Paramètre 'days'"))
    }

    // MARK: - run_shortcut / send_message

    func testRunShortcutMissingName() async throws {
        let got_run_shortcut_name = try await missing("run_shortcut", key: "name")
        XCTAssertEqual(got_run_shortcut_name, strict("name", tool: "run_shortcut"))
    }

    func testRunShortcutWrongTypeName() async throws {
        let r = try await ToolService.shared.execute(name: "run_shortcut", args: ["name": ["x"]])
        XCTAssertEqual(r, strict("name", tool: "run_shortcut"))
    }

    func testSendMessageMissingContact() async throws {
        let r = try await ToolService.shared.execute(name: "send_message", args: ["message": "x"])
        XCTAssertEqual(r, strict("contact", tool: "send_message"))
    }

    func testSendMessageMissingMessage() async throws {
        let r = try await ToolService.shared.execute(name: "send_message", args: ["contact": "x"])
        XCTAssertEqual(r, strict("message", tool: "send_message"))
    }

    func testSendMessageWrongTypes() async throws {
        let r = try await ToolService.shared.execute(name: "send_message", args: ["contact": 1, "message": "x"])
        XCTAssertEqual(r, strict("contact", tool: "send_message"))
    }

    // MARK: - set_clipboard / sleep_mac

    func testSetClipboardMissingText() async throws {
        let got_set_clipboard_text = try await missing("set_clipboard", key: "text")
        XCTAssertEqual(got_set_clipboard_text, strict("text", tool: "set_clipboard"))
    }

    func testSetClipboardWrongTypeText() async throws {
        let r = try await ToolService.shared.execute(name: "set_clipboard", args: ["text": ["x"]])
        XCTAssertEqual(r, strict("text", tool: "set_clipboard"))
    }

    func testSleepMacMissingAction() async throws {
        let got_sleep_mac_action = try await missing("sleep_mac", key: "action")
        XCTAssertEqual(got_sleep_mac_action, strict("action", tool: "sleep_mac"))
    }

    func testSleepMacWrongTypeAction() async throws {
        let r = try await ToolService.shared.execute(name: "sleep_mac", args: ["action": 42])
        XCTAssertEqual(r, strict("action", tool: "sleep_mac"))
    }

    // MARK: - read_url / get_weather / run_routine / remember_fact

    func testReadURLMissingURL() async throws {
        let got_read_url_url = try await missing("read_url", key: "url")
        XCTAssertEqual(got_read_url_url, strict("url", tool: "read_url"))
    }

    func testReadURLWrongTypeURL() async throws {
        let r = try await ToolService.shared.execute(name: "read_url", args: ["url": 42])
        XCTAssertEqual(r, strict("url", tool: "read_url"))
    }

    func testGetWeatherMissingCity() async throws {
        let got_get_weather_city = try await missing("get_weather", key: "city")
        XCTAssertEqual(got_get_weather_city, strict("city", tool: "get_weather"))
    }

    func testGetWeatherWrongTypeCity() async throws {
        let r = try await ToolService.shared.execute(name: "get_weather", args: ["city": true])
        XCTAssertEqual(r, strict("city", tool: "get_weather"))
    }

    func testRunRoutineMissingName() async throws {
        let got_run_routine_name = try await missing("run_routine", key: "name")
        XCTAssertEqual(got_run_routine_name, strict("name", tool: "run_routine"))
    }

    func testRunRoutineWrongTypeName() async throws {
        let r = try await ToolService.shared.execute(name: "run_routine", args: ["name": 42])
        XCTAssertEqual(r, strict("name", tool: "run_routine"))
    }

    func testRememberFactMissingKey() async throws {
        let r = try await ToolService.shared.execute(name: "remember_fact", args: ["value": "x"])
        XCTAssertEqual(r, strict("key", tool: "remember_fact"))
    }

    func testRememberFactMissingValue() async throws {
        let r = try await ToolService.shared.execute(name: "remember_fact", args: ["key": "x"])
        XCTAssertEqual(r, strict("value", tool: "remember_fact"))
    }

    func testRememberFactWrongTypes() async throws {
        let r = try await ToolService.shared.execute(name: "remember_fact", args: ["key": 1, "value": "x"])
        XCTAssertEqual(r, strict("key", tool: "remember_fact"))
    }

    // MARK: - Nouveaux outils (même contrat strict)

    func testCompleteReminderMissingId() async throws {
        let got_complete_reminder_id = try await missing("complete_reminder", key: "id")
        XCTAssertEqual(got_complete_reminder_id, strict("id", tool: "complete_reminder"))
    }

    func testDeleteReminderWrongTypeId() async throws {
        let r = try await ToolService.shared.execute(name: "delete_reminder", args: ["id": 42])
        XCTAssertEqual(r, strict("id", tool: "delete_reminder"))
    }

    func testEditCalendarEventMissingId() async throws {
        let r = try await ToolService.shared.execute(name: "edit_calendar_event", args: ["title": "x"])
        XCTAssertEqual(r, strict("id", tool: "edit_calendar_event"))
    }

    func testEditCalendarEventWrongTypeOptional() async throws {
        // L'id est valide (présent, String) : le refus porte sur l'optionnel,
        // AVANT tout accès EventKit — vert en CI headless.
        let r = try await ToolService.shared.execute(
            name: "edit_calendar_event", args: ["id": "fake-id", "title": 42])
        XCTAssertEqual(r, strict("title", tool: "edit_calendar_event"))
        let r2 = try await ToolService.shared.execute(
            name: "edit_calendar_event", args: ["id": "fake-id", "duration_minutes": "long"])
        XCTAssertEqual(r2, strict("duration_minutes", tool: "edit_calendar_event"))
    }

    func testDeleteCalendarEventMissingId() async throws {
        let got = try await missing("delete_calendar_event", key: "id")
        XCTAssertEqual(got, strict("id", tool: "delete_calendar_event"))
    }

    func testSearchNotesMissingQuery() async throws {
        let got_search_notes_query = try await missing("search_notes", key: "query")
        XCTAssertEqual(got_search_notes_query, strict("query", tool: "search_notes"))
    }

    func testSearchNotesWrongTypeQuery() async throws {
        let r = try await ToolService.shared.execute(name: "search_notes", args: ["query": 42])
        XCTAssertEqual(r, strict("query", tool: "search_notes"))
    }

    func testReadNoteMissingId() async throws {
        let got_read_note_id = try await missing("read_note", key: "id")
        XCTAssertEqual(got_read_note_id, strict("id", tool: "read_note"))
    }

    func testReadNoteWrongTypeId() async throws {
        let r = try await ToolService.shared.execute(name: "read_note", args: ["id": ["x"]])
        XCTAssertEqual(r, strict("id", tool: "read_note"))
    }

    func testListDirectoryMissingPath() async throws {
        let got_list_directory_path = try await missing("list_directory", key: "path")
        XCTAssertEqual(got_list_directory_path, strict("path", tool: "list_directory"))
    }

    func testListDirectoryWrongTypePath() async throws {
        let r = try await ToolService.shared.execute(name: "list_directory", args: ["path": 42])
        XCTAssertEqual(r, strict("path", tool: "list_directory"))
    }

    func testReadFileMissingPath() async throws {
        let got_read_file_path = try await missing("read_file", key: "path")
        XCTAssertEqual(got_read_file_path, strict("path", tool: "read_file"))
    }

    func testReadFileWrongTypePath() async throws {
        let r = try await ToolService.shared.execute(name: "read_file", args: ["path": true])
        XCTAssertEqual(r, strict("path", tool: "read_file"))
    }
}
