import Foundation
import JarvisKit
import JarvisAgent
import JarvisServices

/// L2 — web : `web_search` (cascade éprouvée) + `web_fetch` (lecture bornée).
///
/// Réutilise `WebSearchService`, `BoundedHTTPReader` et le garde anti-SSRF
/// `isBlocked` au lieu de les réécrire. Les deux outils produisent du contenu
/// NON FIABLE (`producesUntrustedContent`) : toute sortie réseau ou écriture
/// ultérieure passe en `ask` (taint tracking).
///
/// `mockPages` : hôte → contenu simulé (grille d'eval : `mock.local…`
/// déterministe, sans réseau). Vide en production.
public struct WebConfig: Sendable {
    public var mockPages: [String: String]
    public var maxPageBytes: Int
    /// Repli simulé quand aucun mock ne matche (grille déterministe).
    /// `nil` en production (vrai réseau).
    public var mockFallbackSearch: String?
    public var mockFallbackPage: String?

    public init(
        mockPages: [String: String] = [:],
        maxPageBytes: Int = 2_000_000,
        mockFallbackSearch: String? = nil,
        mockFallbackPage: String? = nil
    ) {
        self.mockPages = mockPages
        self.maxPageBytes = maxPageBytes
        self.mockFallbackSearch = mockFallbackSearch
        self.mockFallbackPage = mockFallbackPage
    }
}

public enum WebTools {
    public static func definitions(
        config: WebConfig = WebConfig(),
        searchService: WebSearchService = WebSearchService.shared
    ) -> [ToolDefinition] {
        [search(config: config, service: searchService), fetch(config: config)]
    }

    static func search(config: WebConfig, service: WebSearchService) -> ToolDefinition {
        ToolDefinition(
            name: "web_search",
            description: "Recherche sur le web, répond avec sources URL.",
            parameters: WorkspaceTools.stringParams(["query": "requête"]),
            producesUntrustedContent: true
        ) { args, _ in
            let query = args["query"].string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty else {
                return .failure(code: "bad_args", message: "Paramètre 'query' manquant.", hint: "Relis le schéma.")
            }
            if query.lowercased().contains("echoue") {
                return .failure(code: "backend_error", message: "Recherche indisponible (simulée).",
                                hint: "N'essaie pas plus de 2 fois : conclus en échec explicite.")
            }
            if let fallback = config.mockFallbackSearch {
                return .success(JSONValue(fallback))
            }
            let text = await service.search(query: query)
            return .success(JSONValue(text))
        }
    }

    static func fetch(config: WebConfig) -> ToolDefinition {
        ToolDefinition(
            name: "web_fetch",
            description: "Lit une page web publique (http/https) et la résume avec sa source.",
            parameters: WorkspaceTools.stringParams(["url": "URL http(s)"]),
            isNetworkEgress: true,
            producesUntrustedContent: true
        ) { args, _ in
            guard let raw = args["url"].string, let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else {
                return .failure(code: "bad_args", message: "URL http(s) requise.",
                                hint: "N'utilise que des URL publiques http/https.")
            }
            if let host = url.host {
                // Clé la plus longue d'abord : déterministe (mock.local/piege
                // avant mock.local).
                for mockHost in config.mockPages.keys.sorted(by: { $0.count > $1.count }) {
                    if host.contains(mockHost) || raw.contains(mockHost),
                       let content = config.mockPages[mockHost] {
                        return .success(JSONValue(content))
                    }
                }
            }
            if let fallback = config.mockFallbackPage {
                return .success(JSONValue(fallback))
            }
            if URLSafety.isBlocked(url) {
                return .failure(code: "refused",
                                message: "URL refusée par le garde anti-SSRF (hôte local/privé).",
                                hint: "N'utilise que des URL publiques.")
            }
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 30
            do {
                let response = try await BoundedHTTPReader.fetch(
                    request: req, maxBytes: config.maxPageBytes, refuseBinaryMIME: true)
                guard let text = BoundedHTTPReader.decodeText(data: response.data, truncated: response.truncated),
                      !text.isEmpty
                else {
                    return .failure(code: "unreadable", message: "Page illisible ou vide.",
                                    hint: "Décris l'échec au lieu d'inventer.")
                }
                var out = String(text.prefix(6000)) + "\nSources : \(raw)"
                if response.truncated {
                    out += "\n" + BoundedHTTPReader.truncationNote(limit: config.maxPageBytes)
                }
                return .success(JSONValue(out))
            } catch let readerError as BoundedHTTPReader.ReaderError {
                switch readerError {
                case .binaryRefused(let mime):
                    return .failure(code: "binary", message: "Contenu binaire refusé (\(mime)).", hint: "Décris l'échec.")
                case .httpStatus(let code):
                    return .failure(code: "http_\(code)", message: "La page répond \(code).", hint: "Essaie une autre source.")
                case .invalidResponse:
                    return .failure(code: "invalid", message: "Réponse invalide.", hint: "Essaie une autre source.")
                case .network(let detail):
                    return .failure(code: "network", message: "Réseau : \(detail).", hint: "Réessaie une fois.")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .failure(code: "network", message: "Échec réseau : \(error).", hint: "Réessaie une fois.")
            }
        }
    }
}
