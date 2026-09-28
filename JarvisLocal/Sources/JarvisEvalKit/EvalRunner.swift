import Foundation

/// Phase 0 — politique réseau du harnais (et, à terme, de tout client LLM).
///
/// Le trafic Ollama est en HTTP clair, protégé uniquement par le tunnel
/// WireGuard. Règle : HTTP clair autorisé UNIQUEMENT vers un hôte local, vers
/// la plage Tailscale `100.64.0.0/10`, ou vers un nom MagicDNS du tailnet
/// (`*.ts.net`) ; tout autre hôte exige HTTPS. Les redirections vers un autre
/// hôte sont refusées (garde anti-exfiltration après `read_url`).
///
/// Fonctions pures — testées sans réseau.
public enum EvalNetworkPolicy {
    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case emptyURL
        case malformedURL(String)
        case insecureRemoteHost(host: String)
        case redirectToOtherHost(from: String, to: String)

        public var description: String {
            switch self {
            case .emptyURL:
                return "URL de base vide (ni --base-url ni JARVIS_EVAL_BASE_URL)."
            case .malformedURL(let url):
                return "URL malformée : « \(url) »."
            case .insecureRemoteHost(let host):
                return "HTTP clair refusé vers « \(host) » : hors tailnet, HTTPS exigé."
            case .redirectToOtherHost(let from, let to):
                return "Redirection refusée : « \(from) » → « \(to) » (hôte différent)."
            }
        }
    }

    /// Valide une URL de base serveur. Ne code AUCUN hôte en dur : la règle
    /// porte sur des plages / suffixes, l'hôte vient de la config.
    public static func validateBaseURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.emptyURL }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            throw ValidationError.malformedURL(raw)
        }
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "http" && !isInsecureAllowed(host: host.lowercased()) {
            throw ValidationError.insecureRemoteHost(host: host)
        }
        guard scheme == "http" || scheme == "https" else {
            throw ValidationError.malformedURL(raw)
        }
        return url
    }

    /// Une redirection n'est suivie que si l'hôte ne change pas, ou si la
    /// cible reste elle-même autorisée en HTTP clair.
    public static func validateRedirect(from: URL, to: URL) throws {
        let a = from.host?.lowercased() ?? ""
        let b = to.host?.lowercased() ?? ""
        if a == b { return }
        if (to.scheme ?? "").lowercased() == "https" { return }
        if isInsecureAllowed(host: b) { return }
        throw ValidationError.redirectToOtherHost(from: a, to: b)
    }

    static func isInsecureAllowed(host: String) -> Bool {
        if isLocalHostname(host) { return true }
        if host.hasSuffix(".ts.net") { return true }
        if isTailscaleIPv4(host) { return true }
        return false
    }

    static func isLocalHostname(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        let parts = host.split(separator: ".")
        if parts.count == 4, parts[0] == "127",
           parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return true
        }
        return false
    }

    /// `100.64.0.0/10` : premier octet 100, second octet 64–127.
    static func isTailscaleIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts[0] == 100 else { return false }
        return (64...127).contains(parts[1])
    }
}

/// Configuration d'un run d'eval. Toute valeur réseau vient d'argv ou de
/// l'environnement (`JARVIS_EVAL_BASE_URL`, `JARVIS_EVAL_MODEL`,
/// `ANTHROPIC_API_KEY` via Keychain/env, jamais dans le repo).
public struct EvalConfig: Sendable {
    public let baseURL: String
    public let model: String
    public let provider: String
    public let numCtx: Int
    public let evalsDir: String
    public let probeOnly: Bool

    public init(
        baseURL: String,
        model: String,
        provider: String = "ollama",
        numCtx: Int = 16384,
        evalsDir: String = "evals",
        probeOnly: Bool = false
    ) {
        self.baseURL = baseURL
        self.model = model
        self.provider = provider
        self.numCtx = numCtx
        self.evalsDir = evalsDir
        self.probeOnly = probeOnly
    }

    public static func fromArguments(
        _ args: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> EvalConfig {
        var baseURL = environment["JARVIS_EVAL_BASE_URL"]
        var model = environment["JARVIS_EVAL_MODEL"]
        var provider = "ollama"
        var numCtx = 16384
        var evalsDir = "evals"
        var probeOnly = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            func nextValue() -> String? {
                guard index + 1 < args.count else { return nil }
                index += 1
                return args[index]
            }
            if arg == "--base-url", let v = nextValue() { baseURL = v }
            else if arg == "--model", let v = nextValue() { model = v }
            else if arg == "--provider", let v = nextValue() { provider = v }
            else if arg == "--num-ctx", let v = nextValue(), let n = Int(v) { numCtx = n }
            else if arg == "--evals-dir", let v = nextValue() { evalsDir = v }
            else if arg == "--probe-only" { probeOnly = true }
            index += 1
        }
        guard let finalURL = baseURL, !finalURL.isEmpty else {
            throw EvalNetworkPolicy.ValidationError.emptyURL
        }
        guard let finalModel = model, !finalModel.isEmpty else {
            throw EvalConfigError.missingModel
        }
        _ = try EvalNetworkPolicy.validateBaseURL(finalURL)
        return EvalConfig(
            baseURL: finalURL,
            model: finalModel,
            provider: provider,
            numCtx: numCtx,
            evalsDir: evalsDir,
            probeOnly: probeOnly
        )
    }
}

public enum EvalConfigError: Error, Equatable, CustomStringConvertible {
    case missingModel

    public var description: String {
        switch self {
        case .missingModel:
            return "Modèle manquant (--model ou JARVIS_EVAL_MODEL)."
        }
    }
}

/// Chargement des scénarios depuis un dossier `evals/*.yaml`.
public enum EvalLoader {
    public static func loadScenarios(directory: String) throws -> [EvalScenario] {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }
            .sorted()
        return try urls.map { file in
            let path = (directory as NSString).appendingPathComponent(file)
            let text = try String(contentsOfFile: path, encoding: .utf8)
            do {
                return try EvalScenarioParser.parse(yaml: text)
            } catch {
                throw EvalLoaderError.parseFailed(file: file, underlying: "\(error)")
            }
        }
    }
}

public enum EvalLoaderError: Error, Equatable, CustomStringConvertible {
    case parseFailed(file: String, underlying: String)

    public var description: String {
        switch self {
        case .parseFailed(let file, let underlying):
            return "Scénario \(file) illisible : \(underlying)"
        }
    }
}
