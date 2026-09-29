import Foundation
import JarvisKit

/// L3 — monitor de connexion : sonde légère + classification pure.
///
/// RTT (`/api/tags`, sans inférence) et résidence du modèle (`/api/ps`) :
/// le HUD distingue « serveur injoignable » (état normal + réessayer),
/// « modèle en chargement » (durée écoulée) et nominal. Le préchauffage est
/// UNIQUE (au lancement / sur événement réseau, si non résident) — jamais
/// de ping périodique client (cf. `docs/server-setup.md`).
public struct ConnectionProbe: Sendable, Equatable {
    public var reachable: Bool
    public var rttMs: Double?
    public var modelResident: Bool
    public var contextLength: Int?

    public init(reachable: Bool, rttMs: Double? = nil, modelResident: Bool = false, contextLength: Int? = nil) {
        self.reachable = reachable
        self.rttMs = rttMs
        self.modelResident = modelResident
        self.contextLength = contextLength
    }
}

public enum ConnectionMonitor {
    /// Classification pure (testée sans réseau).
    public static func classify(probe: ConnectionProbe, host: String) -> ConnectionState {
        guard probe.reachable else { return .unreachable(host: host) }
        if !probe.modelResident { return .loadingModel(elapsed: 0) }
        return .online(rttMs: probe.rttMs ?? 0, modelResident: true)
    }

    /// Faut-il préchauffer ? Oui si le modèle n'est pas résident.
    /// Le préchauffage LUI-MÊME vit dans `AgentHost` (un seul appel
    /// `/api/generate` avec `keep_alive` long) — ici la pure décision.
    public static func needsWarmup(probe: ConnectionProbe) -> Bool {
        probe.reachable && !probe.modelResident
    }
}

public struct ConnectionProbeRequest: Sendable {
    public var baseURL: URL
    public var model: String
    public var timeout: Double

    public init(baseURL: URL, model: String, timeout: Double = 10) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
    }

    public func run() async -> ConnectionProbe {
        guard let rtt = await tagsRTT() else {
            return ConnectionProbe(reachable: false)
        }
        let ps = await readPs()
        return ConnectionProbe(reachable: true, rttMs: rtt,
                               modelResident: ps != nil, contextLength: ps)
    }

    private func tagsRTT() async -> Double? {
        // Best des 2 tentatives : un échec transitoire ne condamne jamais
        // la sonde (sinon faux `unreachable` alors que le serveur va bien).
        var best: Double?
        for _ in 1...2 {
            var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
            req.timeoutInterval = timeout
            let start = Date()
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let ms = Date().timeIntervalSince(start) * 1000.0
                best = min(best ?? ms, ms)
            } catch {
                continue
            }
        }
        return best
    }

    private func readPs() async -> Int? {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/ps"))
        req.timeoutInterval = timeout
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return nil }
        return models.first { ($0["name"] as? String ?? "").hasPrefix(model) }?["context_length"] as? Int
    }
}
