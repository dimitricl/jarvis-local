@testable import JarvisUI
import JarvisCore
import XCTest

/// Étape 4 : budget par NOM de tool et par tour.
/// Le filtre exact (partitionFreshToolCalls) ne voit que les doublons à args
/// identiques ; ces tests prouvent que le budget coupe une boucle qui reformule
/// sa requête à chaque fois (args toujours différents) — le trou réel.
@MainActor
final class ToolBudgetTests: XCTestCase {
    private func searchCall(query: String) -> ToolCall {
        ToolCall(id: UUID().uuidString, type: "function",
                 function: ToolCallFunction(name: "search_web", arguments: "{\"query\":\"\(query)\"}"))
    }

    private func weatherCall(city: String) -> ToolCall {
        ToolCall(id: UUID().uuidString, type: "function",
                 function: ToolCallFunction(name: "get_weather", arguments: "{\"city\":\"\(city)\"}"))
    }

    func testBudgetAllowsUpToLimitThenRefuses() {
        var counts: [String: Int] = [:]
        for _ in 0..<3 {
            let (allowed, refused) = AppViewModel.partitionBudgetedToolCalls([searchCall(query: "x")], counts: &counts, budget: 3)
            XCTAssertEqual(allowed.count, 1)
            XCTAssertTrue(refused.isEmpty)
        }
        let (allowed, refused) = AppViewModel.partitionBudgetedToolCalls([searchCall(query: "x")], counts: &counts, budget: 3)
        XCTAssertTrue(allowed.isEmpty)
        XCTAssertEqual(refused.count, 1)
    }

    func testBudgetIsPerToolName() {
        var counts: [String: Int] = ["search_web": 3]
        let (allowed, refused) = AppViewModel.partitionBudgetedToolCalls([weatherCall(city: "Paris")], counts: &counts, budget: 3)
        XCTAssertEqual(allowed.count, 1, "un tool épuisé ne doit pas affamer les autres")
        XCTAssertTrue(refused.isEmpty)
        XCTAssertEqual(counts["get_weather"], 1)
        XCTAssertEqual(counts["search_web"], 3, "les refusés n'incrémentent pas le compteur")
    }

    func testBudgetFloorAtOne() {
        var counts: [String: Int] = [:]
        let (allowed, refused) = AppViewModel.partitionBudgetedToolCalls(
            [searchCall(query: "a"), searchCall(query: "b")], counts: &counts, budget: 0)
        XCTAssertEqual(allowed.count, 1, "budget <= 0 = plancher à 1, jamais 0 (sinon aucun outil ne tourne)")
        XCTAssertEqual(refused.count, 1)
    }

    /// Preuve demandée : 10 itérations de search_web aux args TOUJOURS différents
    /// (le filtre exact laisse tout passer — trou vérifié par l'assertion interne),
    /// budget 3 → exactement 3 exécutions, la boucle est coupée avant N=10.
    func testSearchWebLoopCutBeforeNIterations() {
        var seen = Set<String>()
        var counts: [String: Int] = [:]
        let budget = 3
        var executed = 0
        for i in 0..<10 {
            let batch = [searchCall(query: "boucle \(i)")]
            let (fresh, _) = AppViewModel.partitionFreshToolCalls(batch, seen: &seen)
            XCTAssertEqual(fresh.count, 1, "le filtre exact laisse passer : args différents à chaque tour")
            let (allowed, refused) = AppViewModel.partitionBudgetedToolCalls(fresh, counts: &counts, budget: budget)
            executed += allowed.count
            if i >= budget {
                XCTAssertTrue(allowed.isEmpty, "itération \(i) : aurait dû être coupée")
                XCTAssertEqual(refused.count, 1)
            }
        }
        XCTAssertEqual(executed, budget, "boucle search_web coupée à \(budget) exécutions sur 10 tentatives")
    }

    /// Empilement des deux gardes : doublon exact refusé sans consommer de budget,
    /// puis budget appliqué au reste.
    func testExactDuplicatesDoNotConsumeBudget() {
        var seen = Set<String>()
        var counts: [String: Int] = [:]
        let same = searchCall(query: "météo")
        let (fresh1, dups1) = AppViewModel.partitionFreshToolCalls([same], seen: &seen)
        let (allowed1, _) = AppViewModel.partitionBudgetedToolCalls(fresh1, counts: &counts, budget: 1)
        XCTAssertEqual(allowed1.count, 1)
        XCTAssertTrue(dups1.isEmpty)

        let retry = ToolCall(id: UUID().uuidString, type: "function",
                             function: ToolCallFunction(name: "search_web", arguments: "{\"query\":\"météo\"}"))
        let (fresh2, dups2) = AppViewModel.partitionFreshToolCalls([retry], seen: &seen)
        XCTAssertTrue(fresh2.isEmpty, "doublon exact filtré avant le budget")
        XCTAssertEqual(dups2.count, 1)
        XCTAssertEqual(counts["search_web"], 1, "le doublon n'a pas consommé de budget")
    }
}
