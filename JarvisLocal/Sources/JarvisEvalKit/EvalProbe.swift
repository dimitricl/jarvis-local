import Foundation

/// Phase 0 — introspection du serveur d'inférence distant.
///
/// Le rapport d'eval DOIT séparer trois latences que le ressenti « c'est lent »
/// confond : (1) latence réseau RTT vers le serveur (mesurée sur `GET /api/tags`,
/// sans inférence), (2) chargement à froid du modèle (`load_duration`), (3)
/// inférence (`prompt_eval_duration` + `eval_duration`). Sans cette séparation,
/// impossible de dire si un hotkey lent vient du lien Tailscale, du modèle
/// déchargé, ou du prompt.
///
/// De même, le contexte RÉELLEMENT alloué (`GET /api/ps` → `context_length`,
/// `size_vram` vs `size`) est consigné : tout `num_ctx` demandé au-delà est
/// tronqué silencieusement par Ollama, et un modèle partiellement hors GPU
/// change radicalement la latence.
public struct ServerProbe: Sendable, Equatable {
    /// RTT réseau pur (ms) mesuré sur un endpoint sans inférence.
    public let rttMs: Double
    /// Le modèle évalué est-il résident en mémoire au moment de la sonde ?
    public let modelResident: Bool
    /// Contexte réellement alloué côté serveur (nil si non résident / inconnu).
    public let contextLength: Int?
    /// VRAM occupée vs taille totale du modèle (octets, nil si inconnues).
    public let sizeVRAM: Int?
    public let sizeTotal: Int?
    /// Avertissements tête de rapport : partiel GPU, contexte < demandé.
    public let warnings: [String]

    public init(
        rttMs: Double,
        modelResident: Bool,
        contextLength: Int?,
        sizeVRAM: Int?,
        sizeTotal: Int?,
        warnings: [String]
    ) {
        self.rttMs = rttMs
        self.modelResident = modelResident
        self.contextLength = contextLength
        self.sizeVRAM = sizeVRAM
        self.sizeTotal = sizeTotal
        self.warnings = warnings
    }
}

/// Durées renvoyées par Ollama dans une réponse de génération (nanosecondes).
/// `load_duration` > 0 ⇒ le modèle a été (re)chargé : latence à froid, pas du réseau.
public struct InferenceMetrics: Sendable, Equatable {
    public let loadDurationNs: Int?
    public let promptEvalDurationNs: Int?
    public let evalDurationNs: Int?
    public let promptEvalCount: Int?
    public let evalCount: Int?

    public init(
        loadDurationNs: Int?,
        promptEvalDurationNs: Int?,
        evalDurationNs: Int?,
        promptEvalCount: Int?,
        evalCount: Int?
    ) {
        self.loadDurationNs = loadDurationNs
        self.promptEvalDurationNs = promptEvalDurationNs
        self.evalDurationNs = evalDurationNs
        self.promptEvalCount = promptEvalCount
        self.evalCount = evalCount
    }

    /// Inférence pure (prompt_eval + eval), hors chargement, en ms.
    public var inferenceMs: Double? {
        guard let p = promptEvalDurationNs, let e = evalDurationNs else { return nil }
        return Double(p + e) / 1_000_000.0
    }

    /// true si ce run a payé un chargement à froid (> 1 s de load).
    public var paidColdLoad: Bool {
        (loadDurationNs ?? 0) > 1_000_000_000
    }
}

public enum ProbeParseError: Error, Equatable {
    case invalidJSON
    case unexpectedShape(String)
}

/// Entrée `models[]` de `GET /api/ps`, parsée en pur (testable sans serveur).
public struct PsModelInfo: Sendable, Equatable {
    public let name: String
    public let contextLength: Int?
    public let sizeVRAM: Int?
    public let sizeTotal: Int?

    public init(name: String, contextLength: Int?, sizeVRAM: Int?, sizeTotal: Int?) {
        self.name = name
        self.contextLength = contextLength
        self.sizeVRAM = sizeVRAM
        self.sizeTotal = sizeTotal
    }
}

public enum ServerProbeParsing {
    /// Parse le corps JSON de `GET /api/ps` (`{"models": [...]}`).
    /// Chaque modèle porte `context_length`, `size_vram` et `size`.
    public static func parsePs(data: Data) throws -> [PsModelInfo] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProbeParseError.invalidJSON
        }
        guard let dict = json as? [String: Any] else {
            throw ProbeParseError.unexpectedShape("racine non-objet")
        }
        let models = dict["models"] as? [[String: Any]] ?? []
        return models.map { m in
            PsModelInfo(
                name: (m["name"] as? String) ?? (m["model"] as? String) ?? "?",
                contextLength: intValue(m["context_length"]),
                sizeVRAM: intValue(m["size_vram"]),
                sizeTotal: intValue(m["size"])
            )
        }
    }

    /// Construit les avertissements tête de rapport pour le modèle évalué.
    /// - `requestedNumCtx` : le `num_ctx` demandé (réglage client).
    /// - Signale si `context_length` < demandé (troncation silencieuse côté
    ///   serveur) et si le modèle est partiellement hors GPU.
    public static func warnings(
        for model: PsModelInfo?,
        requestedNumCtx: Int,
        modelName: String
    ) -> [String] {
        guard let model else {
            return ["Modèle « \(modelName) » non résident au moment de la sonde : le premier run paiera un chargement à froid (~20 s constaté)."]
        }
        var out: [String] = []
        if let ctx = model.contextLength, ctx < requestedNumCtx {
            out.append("Contexte réel \(ctx) < num_ctx demandé \(requestedNumCtx) : Ollama tronque silencieusement au-delà. Baisser num_ctx ou libérer de la VRAM.")
        }
        if let vram = model.sizeVRAM, let total = model.sizeTotal, total > 0, vram < total {
            let pct = Int((Double(vram) / Double(total) * 100).rounded())
            out.append("Modèle partiellement hors GPU (\(pct) % en VRAM) : latence d'inférence dégradée, à consigner avec les temps mesurés.")
        }
        return out
    }

    /// Parse les durées d'une réponse Ollama (`/api/chat` non-stream ou
    /// `/v1/chat/completions` : mêmes clés `load_duration`, etc.).
    public static func parseMetrics(data: Data) -> InferenceMetrics? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func ns(_ key: String) -> Int? { intValue(json[key]) }
        let hasAny = json["load_duration"] != nil || json["prompt_eval_duration"] != nil
            || json["eval_duration"] != nil || json["prompt_eval_count"] != nil
        guard hasAny else { return nil }
        return InferenceMetrics(
            loadDurationNs: ns("load_duration"),
            promptEvalDurationNs: ns("prompt_eval_duration"),
            evalDurationNs: ns("eval_duration"),
            promptEvalCount: ns("prompt_eval_count"),
            evalCount: ns("eval_count")
        )
    }

    /// Estimation tokens → caractères calibrée : quand `prompt_eval_count` est
    /// renvoyé par Ollama on compte en tokens réels ; sinon repli ~4 car/token
    /// (même heuristique que le prototype TS, documentée comme borne).
    public static func estimatePromptTokens(promptEvalCount: Int?, charCount: Int) -> (value: Int, calibrated: Bool) {
        if let n = promptEvalCount { return (n, true) }
        return (max(1, charCount / 4), false)
    }

    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
}
