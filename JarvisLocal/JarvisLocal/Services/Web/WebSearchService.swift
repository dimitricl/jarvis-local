import Foundation
#if canImport(SwiftSoup)
import SwiftSoup
#endif

/// Résultat web normalisé : titre + URL absolue + extrait texte.
/// Pourquoi un type propre : l'ancien code manipulait des tuples anonymes
/// (title, href) où `href` pouvait être relatif (redirection DDG) — ambigu
/// et source de citations cassées. Ici `url` est TOUJOURS absolue.
struct WebSearchResult: Sendable, Equatable {
    let title: String
    let url: String
    let snippet: String?
}

/// Fournisseur de recherche web en cascade :
///  1. DuckDuckGo Instant Answer API (officielle, JSON stable, sans clé)
///  2. DuckDuckGo Lite parsé en DOM (SwiftSoup, sélecteurs CSS)
///  3. Fallback regex legacy (format peut-être changé → message explicite)
/// Pourquoi cet ordre : l'API officielle ne casse jamais mais est pauvre
/// (définitions / désambiguïsations) ; le DOM donne les vrais résultats ;
/// la regex n'est qu'un filet de sécurité en attendant la mise à jour des
/// sélecteurs. Aucune passe ne fait planter le tour : échec = texte explicite.
/// Pourquoi un actor isolé : l'ancien searchWeb vivait dans le monolithe
/// ToolService, intestable sans réseau ni EventKit. Ici tout le parsing est
/// en fonctions pures `static` testables sans actor ni réseau.
actor WebSearchService {
    static let shared = WebSearchService()

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Point d'entrée unique appelé par ToolService / WebTools.
    /// Ne throw jamais sur panne réseau : retourne un texte explicite pour
    /// que le modèle réponde avec ses connaissances au lieu de planter le tour.
    func search(query: String) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "Requête vide : précise ce que tu veux chercher." }

        // Passe 1 : API officielle Instant Answer (stable, pas de scraping).
        if let instant = await instantAnswer(query: q), !instant.isEmpty {
            return instant
        }

        // Passe 2 : Lite + DOM.
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://lite.duckduckgo.com/lite/?q=\(encoded)")
        else { return "Erreur d'encodage de la requête." }

        guard let html = await fetchPage(searchURL, timeout: 30) else {
            return "Recherche web indisponible (pas de réponse de DuckDuckGo). Réponds avec tes connaissances générales en précisant que tu n'as pas pu vérifier en ligne."
        }

        var links = parseDOM(html, base: searchURL)
        // Passe 3 : fallback regex si le DOM ne donne rien (markup changé).
        // Pourquoi garder la regex : mieux vaut 3 résultats approximatifs
        // qu'un échec sec pendant qu'on met à jour les sélecteurs.
        var viaFallback = false
        if links.isEmpty {
            links = Self.parseLegacyRegex(html)
            viaFallback = !links.isEmpty
        }

        if links.isEmpty {
            return "Aucun résultat trouvé pour \"\(q)\". Le format de la page DuckDuckGo a peut-être changé, ou la requête n'a rien donné."
        }

        // Top-3 téléchargés EN PARALLÈLE (TaskGroup) : en séquentiel, une page
        // lente de 15s retardait d'autant tout le résultat.
        let top = Array(links.prefix(3))
        let texts = await fetchTopPages(top, base: searchURL)
        var resolved: [(title: String, href: String, text: String?)] = []
        for (i, r) in top.enumerated() {
            // Les href DDG sont souvent relatifs ou des redirections
            // //duckduckgo.com/l/… : on résout en absolu pour citation.
            let abs = URL(string: r.href, relativeTo: searchURL)?.absoluteString ?? r.href
            resolved.append((title: r.title, href: abs, text: texts[i]))
        }
        var out = Self.format(resolved)
        if viaFallback {
            out += "\n\n[Note : résultats extraits en mode dégradé — le format DuckDuckGo semble avoir changé.]"
        }
        return out
    }

    // MARK: - Passe 1 : Instant Answer API officielle

    /// https://api.duckduckgo.com/?q=...&format=json — sans clé.
    /// Retourne nil si pas de réponse exploitable (cas général) pour
    /// laisser la main au scraping DOM.
    private func instantAnswer(query: String) async -> String? {
        guard let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.duckduckgo.com/?q=\(enc)&format=json&no_html=1&skip_disambig=0")
        else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let abstract = (json["AbstractText"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let source = (json["AbstractURL"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = (json["Heading"] as? String ?? "")
        guard !abstract.isEmpty else { return nil }
        var out = "--- \(heading.isEmpty ? query : heading) ---\n"
        if !source.isEmpty { out += "Source : \(source)\n" }
        out += "Contenu : \(abstract)"
        return out
    }

    // MARK: - Passe 2 : DOM via SwiftSoup

    /// Parse DOM : sélecteurs sur `a.result-link` / `a.result__a`.
    /// `nonisolated` + `static` : fonction pure, testable sans actor ni réseau.
    nonisolated static func parseDOMStatic(_ html: String, base: URL) -> [(title: String, href: String)] {
        #if canImport(SwiftSoup)
        do {
            let doc = try SwiftSoup.parse(html, base.absoluteString)
            // Deux sélecteurs historiques de DDG Lite ; on les essaie dans l'ordre.
            // Pourquoi plusieurs : DDG a déjà renommé `result-link` en `result__a` une fois.
            for sel in ["a.result-link", "a.result__a", ".result a[href]"] {
                let els = try doc.select(sel)
                var out: [(String, String)] = []
                for el in els.array().prefix(5) {
                    // abs:href résout les relatifs via le baseUri du parse ;
                    // fallback sur href brut si vide.
                    let abs = (try? el.attr("abs:href")) ?? ""
                    let raw = (try? el.attr("href")) ?? ""
                    let href = abs.isEmpty ? raw : abs
                    let title = ((try? el.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !href.isEmpty, !title.isEmpty, !href.contains("duckduckgo.com/y.js") else { continue }
                    out.append((title, href))
                }
                if !out.isEmpty { return out }
            }
            return []
        } catch {
            return []
        }
        #else
        // Sans SwiftSoup (CI sans dépendances) : pas de DOM, on laisse
        // le fallback regex prendre le relais — jamais d'échec sec.
        return []
        #endif
    }

    private func parseDOM(_ html: String, base: URL) -> [(title: String, href: String)] {
        Self.parseDOMStatic(html, base: base)
    }

    // MARK: - Passe 3 : fallback regex legacy

    /// Regex d'urgence si les sélecteurs DOM ne matchent plus.
    /// Pourquoi conservée : un changement de markup ne doit pas rendre
    /// search_web muet en attendant la mise à jour des sélecteurs.
    nonisolated static func parseLegacyRegex(_ html: String) -> [(title: String, href: String)] {
        let patterns = [
            #"<a[^>]*class="result-link"[^>]*href="([^"]*)"[^>]*>([^<]*)</a>"#,
            #"<a[^>]*href="([^"]*)"[^>]*class="result-link"[^>]*>([^<]*)</a>"#,
            #"<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>([^<]*)</a>"#,
            #"<a[^>]*rel="nofollow"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#,
        ]
        for pattern in patterns {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
            let matches = rx.matches(in: html, range: NSRange(html.startIndex..., in: html))
            var out: [(String, String)] = []
            for m in matches.prefix(5) {
                guard m.range(at: 1).location != NSNotFound, m.range(at: 2).location != NSNotFound,
                      let href = Range(m.range(at: 1), in: html).map({ String(html[$0]) }),
                      let title = Range(m.range(at: 2), in: html).map({ String(html[$0]).strippedHTML }),
                      !href.isEmpty, !title.isEmpty
                else { continue }
                out.append((title, href))
            }
            if !out.isEmpty { return out }
        }
        return []
    }

    // MARK: - Réseau mutualisé

    /// Fetch générique : UA navigateur + timeout court. Une requête qui traîne
    /// ne doit jamais bloquer tout le tour de conversation.
    private func fetchPage(_ url: URL, timeout: TimeInterval) async -> String? {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = timeout
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        return html
    }

    private func fetchTopPages(_ links: [(title: String, href: String)], base: URL) async -> [String?] {
        await withTaskGroup(of: (Int, String?).self) { group in
            for (i, r) in links.enumerated() {
                group.addTask { [weak self] in
                    guard let self,
                          let u = URL(string: r.href, relativeTo: base),
                          let html = await self.fetchPage(u, timeout: 15)
                    else { return (i, nil) }
                    let t = html.htmlToText(maxLength: 3000)
                    return (i, t.count > 100 ? t : nil)
                }
            }
            var col: [Int: String?] = [:]
            for await (i, t) in group { col[i] = t }
            return links.indices.map { col[$0] ?? nil }
        }
    }

    /// Mise en forme avec Source URL obligatoire (auditabilité : avant, le
    /// modèle ne POUVAIT pas citer ses sources, cf. cas iPhone 18 Pro).
    /// `internal`/`static` pour les tests.
    nonisolated static func format(_ results: [(title: String, href: String, text: String?)]) -> String {
        var out = ""
        for r in results {
            out += "--- \(r.title) ---\nSource : \(r.href)\n"
            if let t = r.text { out += "Contenu : \(t)\n" }
            out += "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
