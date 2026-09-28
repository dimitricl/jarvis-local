import Foundation
import JarvisEvalKit

/// CLI `JarvisEval` — harnais de benchmark d'agent (Phase 0).
///
/// Usage :
///   JarvisEval --base-url <url> --model <nom> [--provider ollama|anthropic]
///              [--num-ctx 16384] [--evals-dir evals] [--probe-only]
///
/// Config par env : JARVIS_EVAL_BASE_URL, JARVIS_EVAL_MODEL.
/// Clé Anthropic (référence cloud) : ANTHROPIC_API_KEY dans l'environnement
/// ou le Keychain — jamais en argv, jamais dans le repo.
///
/// Sortie : tableau Markdown (alertes d'allocation en tête, RTT séparé de
/// l'inférence) + JSON sur stdout avec `--json` ? (v1 : Markdown seul).
/// Serveur injoignable = état normal affiché en une ligne, code de sortie 3.
private func printUsage() {
    let text = """
    Usage: JarvisEval --base-url <url> --model <nom> [options]
      --provider ollama|anthropic   (défaut: ollama)
      --num-ctx <n>                 (défaut: 16384)
      --evals-dir <dossier>         (défaut: evals)
      --probe-only                  (sonde /api/tags + /api/ps, sans scénarios)
    Env: JARVIS_EVAL_BASE_URL, JARVIS_EVAL_MODEL, ANTHROPIC_API_KEY.
    """
    FileHandle.standardError.write(Data(text.utf8))
}

private struct ProbeOutcome {
    let rttMs: Double
    let psModels: [PsModelInfo]
}

private func measureTagsRTT(base: URL) async -> Double? {
    // 3 mesures, minimum retenu (pratique standard : écarte les à-coups,
    // ex. relais DERP lent ou requête coincée derrière un chargement).
    var best: Double?
    for _ in 1...3 {
        let url = base.appendingPathComponent("api/tags")
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let start = Date()
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let ms = Date().timeIntervalSince(start) * 1000.0
            best = min(best ?? ms, ms)
        } catch {
            return nil
        }
    }
    return best
}

private func fetchPs(base: URL) async -> [PsModelInfo] {
    let url = base.appendingPathComponent("api/ps")
    var req = URLRequest(url: url)
    req.timeoutInterval = 10
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? ServerProbeParsing.parsePs(data: data)) ?? []
    } catch {
        return []
    }
}

private func runCLI() async -> Int32 {
    let rawArgs = Array(CommandLine.arguments.dropFirst())
    if rawArgs.contains("--help") || rawArgs.contains("-h") {
        printUsage()
        return 0
    }
    let config: EvalConfig
    do {
        config = try EvalConfig.fromArguments(rawArgs)
    } catch {
        FileHandle.standardError.write(Data("Erreur de configuration : \(error)\n".utf8))
        printUsage()
        return 2
    }
    guard let base = try? EvalNetworkPolicy.validateBaseURL(config.baseURL) else {
        FileHandle.standardError.write(Data("URL de base refusée par la politique réseau.\n".utf8))
        return 2
    }
    let host = base.host ?? "?"

    // Sonde réseau pure (sans inférence) puis état mémoire du serveur.
    guard let rtt = await measureTagsRTT(base: base) else {
        // État normal à afficher, pas une erreur : le lien peut être down.
        print("serveur injoignable (\(host)) — réessayez avec le Mac mini allumé et Tailscale connecté.")
        return 3
    }
    let psModels = await fetchPs(base: base)
    let match = psModels.first { $0.name == config.model || $0.name.hasPrefix(config.model) }
    let warnings = ServerProbeParsing.warnings(for: match, requestedNumCtx: config.numCtx, modelName: config.model)
    let ctxActual = match?.contextLength
    let rttText = String(format: "%.0f", rtt)
    print("Sonde OK — hôte \(host), RTT réseau pur : \(rttText) ms (GET /api/tags, sans inférence).")
    if let m = match {
        print("Modèle résident : \(m.name), context_length réel : \(m.contextLength.map(String.init) ?? "inconnu").")
    } else {
        print("Modèle « \(config.model) » non résident : le premier run paiera un chargement à froid.")
    }
    for w in warnings { print("⚠️ \(w)") }

    if config.probeOnly { return 0 }

    guard config.provider == "ollama" else {
        FileHandle.standardError.write(Data("Exécution live non supportée pour --provider \(config.provider) (référence cloud indisponible : matrice locale uniquement).\n".utf8))
        return 2
    }

    // Chargement des scénarios puis exécution live : un workspace bac à
    // sable par scénario (fixtures montées, effets réels confinés), boucle
    // d'agent (†EvalAgentLoop), vérification par code (EvalChecker).
    let scenarios: [EvalScenario]
    do {
        scenarios = try EvalLoader.loadScenarios(directory: config.evalsDir)
    } catch {
        FileHandle.standardError.write(Data("Chargement evals impossible : \(error)\n".utf8))
        return 2
    }
    let transport = OllamaEvalTransport(baseURL: base)
    var results: [ScenarioResult] = []
    for scenario in scenarios {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-eval-\(scenario.name)", isDirectory: true)
        try? FileManager.default.removeItem(at: workspace)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        for (name, content) in scenario.fixtureFiles {
            try? content.write(to: workspace.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        FileHandle.standardError.write(Data("→ \(scenario.name)…\n".utf8))
        let live = await EvalAgentLoop.run(
            scenario: scenario, model: config.model, numCtx: config.numCtx,
            workspace: workspace.path, transport: transport)
        let (tokens, calibrated) = ServerProbeParsing.estimatePromptTokens(
            promptEvalCount: live.tokensCalibrated ? live.promptTokens : nil,
            charCount: scenario.prompt.count)
        results.append(ScenarioResult(
            name: scenario.name, category: scenario.category, status: live.status,
            steps: live.steps, rttMs: rtt, loadMs: live.loadMs, inferenceMs: live.inferenceMs,
            promptTokens: tokens, tokensCalibrated: calibrated, note: live.note))
        FileHandle.standardError.write(Data("  \(live.status) (\(live.steps) étapes) — \(live.note)\n".utf8))
        try? FileManager.default.removeItem(at: workspace)
    }
    let dateISO = ISO8601DateFormatter().string(from: Date())
    let report = EvalReport(
        model: config.model,
        provider: config.provider,
        host: host,
        numCtxRequested: config.numCtx,
        contextLengthActual: ctxActual,
        warnings: warnings,
        results: results,
        dateISO: dateISO
    )
    print("")
    print(EvalReportRendering.renderMarkdown(report))
    return 0
}

let code = await runCLI()
exit(code)
