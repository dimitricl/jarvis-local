import Foundation

/// Phase 0 — résultats et rendu du rapport d'eval.
///
/// Le rapport sépare TOUJOURS latence réseau (RTT) et latence d'inférence
/// (`load` vs `prompt_eval` + `eval`), et affiche en tête les alertes
/// d'allocation (partiel GPU, `context_length` < `num_ctx` demandé).
/// Sans cette discipline, un benchmark local-vs-cloud ne veut rien dire.
public struct ScenarioResult: Sendable, Codable, Equatable {
    public let name: String
    public let category: String
    /// `passed` / `failed` / `skipped` (serveur injoignable = état normal, pas erreur).
    public let status: String
    public let steps: Int
    /// RTT réseau pur (ms) — `GET /api/tags`, sans inférence.
    public let rttMs: Double?
    /// Chargement modèle (ms) — `load_duration`, nil si non mesuré.
    public let loadMs: Double?
    /// Inférence pure (ms) — `prompt_eval_duration + eval_duration`.
    public let inferenceMs: Double?
    /// Tokens du prompt : `prompt_eval_count` quand renvoyé (calibré), sinon
    /// estimation ~4 car/token (`tokensCalibrated == false`).
    public let promptTokens: Int?
    public let tokensCalibrated: Bool
    public let note: String

    public init(
        name: String,
        category: String,
        status: String,
        steps: Int,
        rttMs: Double?,
        loadMs: Double?,
        inferenceMs: Double?,
        promptTokens: Int?,
        tokensCalibrated: Bool,
        note: String
    ) {
        self.name = name
        self.category = category
        self.status = status
        self.steps = steps
        self.rttMs = rttMs
        self.loadMs = loadMs
        self.inferenceMs = inferenceMs
        self.promptTokens = promptTokens
        self.tokensCalibrated = tokensCalibrated
        self.note = note
    }

    public static func skipped(name: String, category: String, note: String) -> ScenarioResult {
        ScenarioResult(
            name: name, category: category, status: "skipped", steps: 0,
            rttMs: nil, loadMs: nil, inferenceMs: nil,
            promptTokens: nil, tokensCalibrated: false, note: note
        )
    }
}

public struct EvalReport: Sendable, Codable, Equatable {
    public let model: String
    public let provider: String
    /// Hôte seul (pas d'URL complète) : le rapport ne recopie jamais
    /// d'identifiant réseau précis au-delà du nécessaire.
    public let host: String
    public let numCtxRequested: Int
    public let contextLengthActual: Int?
    public let warnings: [String]
    public let results: [ScenarioResult]
    public let dateISO: String

    public init(
        model: String,
        provider: String,
        host: String,
        numCtxRequested: Int,
        contextLengthActual: Int?,
        warnings: [String],
        results: [ScenarioResult],
        dateISO: String
    ) {
        self.model = model
        self.provider = provider
        self.host = host
        self.numCtxRequested = numCtxRequested
        self.contextLengthActual = contextLengthActual
        self.warnings = warnings
        self.results = results
        self.dateISO = dateISO
    }

    public var passed: Int { results.filter { $0.status == "passed" }.count }
    public var failed: Int { results.filter { $0.status == "failed" }.count }
    public var skipped: Int { results.filter { $0.status == "skipped" }.count }
    public var successRate: Double {
        let decided = passed + failed
        guard decided > 0 else { return 0 }
        return Double(passed) / Double(decided)
    }
}

public enum EvalReportRendering {
    /// Rendu Markdown : alertes en tête, puis une ligne par scénario avec
    /// RTT / load / inférence en colonnes SÉPARÉES, puis taux de réussite.
    public static func renderMarkdown(_ report: EvalReport) -> String {
        var lines: [String] = []
        lines.append("# Rapport d'évaluation — \(report.model) (\(report.provider))")
        lines.append("")
        lines.append("- Date : \(report.dateISO)")
        lines.append("- Hôte : \(report.host)")
        lines.append("- num_ctx demandé : \(report.numCtxRequested)")
        lines.append("- context_length réel : \(report.contextLengthActual.map(String.init) ?? "inconnu")")
        lines.append("")
        if !report.warnings.isEmpty {
            lines.append("## ⚠️ Alertes d'allocation")
            lines.append("")
            for w in report.warnings { lines.append("- \(w)") }
            lines.append("")
        }
        lines.append("## Résultats (\(report.passed)/\(report.passed + report.failed) réussis, \(report.skipped) ignorés)")
        lines.append("")
        lines.append("| Scénario | Catégorie | Statut | Étapes | RTT (ms) | Load (ms) | Inférence (ms) | Tokens prompt | Note |")
        lines.append("|---|---|---|---|---|---|---|---|---|")
        for r in report.results {
            let row = "| \(r.name) | \(r.category) | \(r.status) | \(r.steps) | \(ms(r.rttMs)) | \(ms(r.loadMs)) | \(ms(r.inferenceMs)) | \(tok(r)) | \(r.note) |"
            lines.append(row)
        }
        lines.append("")
        lines.append("RTT = réseau pur (`GET /api/tags`, sans inférence). Load = `load_duration` (chargement à froid). Inférence = `prompt_eval_duration + eval_duration`.")
        return lines.joined(separator: "\n")
    }

    private static func ms(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.0f", v)
    }

    private static func tok(_ r: ScenarioResult) -> String {
        guard let t = r.promptTokens else { return "—" }
        return r.tokensCalibrated ? "\(t)" : "~\(t)"
    }
}
