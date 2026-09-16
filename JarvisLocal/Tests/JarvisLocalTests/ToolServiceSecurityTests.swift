@testable import JarvisUI
import JarvisCore
@testable import JarvisServices
import XCTest

// MARK: - ToolService Security
final class JarvisLocalToolServiceSecurityTests: XCTestCase {
    func testToolDefsAreNotEmpty() async {
        let tools = ToolService.shared
        let defs = await tools.toolDefs
        XCTAssertGreaterThan(defs.count, 0)
    }

    func testAllToolsHaveRequiredFields() async {
        let tools = ToolService.shared
        let defs = await tools.toolDefs
        for t in defs {
            XCTAssertFalse(t.function.name.isEmpty, "Tool name should not be empty")
            XCTAssertFalse(t.function.description.isEmpty, "Tool \(t.function.name) description should not be empty")
        }
    }

    @MainActor
    func testSensitiveToolsHaveConfirmationInViewModel() async {
        // AVANT : ce test recopiait la liste sensitiveTools à la main dans le test lui-même.
        // Un test qui compare une copie à elle-même sous un autre nom ne vérifie rien : si demain
        // quelqu'un retire "remember_fact" (ou n'importe quel autre tool) de la VRAIE liste dans
        // AppViewModel, ce test continue de passer au vert puisqu'il ne regarde jamais le vrai code.
        // Ici on instancie le vrai AppViewModel et on lit sa propriété réelle.
        let viewModel = AppViewModel()
        let defs = await ToolService.shared.toolDefs
        let toolNames = Set(defs.map { $0.function.name })

        for s in viewModel.sensitiveTools {
            XCTAssertTrue(toolNames.contains(s), "Sensitive tool \(s) déclaré dans AppViewModel mais absent de ToolService.toolDefs")
        }
    }

    /// Garde-fou dans l'autre sens : verrouille explicitement l'ensemble des tools qui ÉCRIVENT ou
    /// AGISSENT sur le système, pour qu'un nouveau tool à effet de bord ajouté plus tard sans être
    /// classé "sensible" fasse échouer CE test au lieu de passer inaperçu en confirmation silencieuse.
    /// À mettre à jour manuellement à chaque nouveau tool à effet de bord — c'est le seul endroit du
    /// projet qui force à se poser explicitement la question "confirmation obligatoire ou pas ?".
    func testKnownSideEffectToolsAreAllMarkedSensitive() async {
        let sideEffectTools: Set<String> = [
            "sleep_mac", "send_message", "create_note", "open_app", "get_clipboard",
            "edit_note", "run_shortcut", "remember_fact", "add_calendar_event", "add_reminder",
            "set_clipboard", "search_maps", "take_screenshot",
            "complete_reminder", "delete_reminder", "edit_calendar_event", "delete_calendar_event"
        ]
        let viewModel = await MainActor.run { AppViewModel() }
        let sensitive = await MainActor.run { viewModel.sensitiveTools }
        let defs = await ToolService.shared.toolDefs
        let existingToolNames = Set(defs.map { $0.function.name })

        for tool in sideEffectTools where existingToolNames.contains(tool) {
            XCTAssertTrue(
                sensitive.contains(tool),
                "\(tool) a un effet de bord réel mais n'est PAS dans sensitiveTools : il s'exécute sans confirmation utilisateur."
            )
        }
    }
}
