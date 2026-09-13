import Foundation

/// Heuristique d'extraction de faits, extraite à l'identique de AppViewModel.
/// Pourquoi une struct pure : avant, `extractCandidateFacts` était une méthode
/// du ViewModel @MainActor — intestable sans instancier toute l'UI et sa DB.
/// Ici : aucune dépendance DB/UI/MainActor, tests directs et instantanés.
/// Comportement strictement identique (mêmes patterns, mêmes listes) : les
/// tests AppViewModel existants restent verts via la délégation ci-dessous.
///
/// Extraction volontairement simple (regex, pas de NER). Ça rate des cas et
/// capte parfois du bruit — choix assumé : un faux positif n'a aucune
/// conséquence tant que rien n'est écrit sans confirmation explicite après.
struct FactExtractor: Sendable {
    private static let factPatterns: [(key: String, regex: NSRegularExpression)] = {
        let patterns: [(String, String)] = [
            ("user.name", #"(?:je m'appelle|mon nom est|mon pr[ée]nom est)\s+([A-ZÀ-Ý][\wÀ-ÿ'-]+(?:\s+[A-ZÀ-Ý][\wÀ-ÿ'-]+)?)"#),
            // "je suis X" / "moi c'est X" : la formulation la plus courante ("je suis Dimitri"),
            // qui passait avant au travers — le modèle répondait "je vais m'en souvenir" sans
            // rien enregistrer. Filtrée par nameValueExclusions (adjectifs, métiers, locutions).
            ("user.name", #"(?:je suis|moi c[’']est|c[’']est moi)\s+([A-ZÀ-Ý][\wÀ-ÿ'-]+(?:\s+[A-ZÀ-Ý][\wÀ-ÿ'-]+)?)"#),
            ("user.city", #"(?:j'habite\s+(?:à|a|au|en)|je vis\s+(?:à|a|au|en))\s+([A-ZÀ-Ý][\wÀ-ÿ'-]+)"#),
            ("user.birthday", #"(?:je suis né(?:e)?\s+le|mon anniversaire\s+(?:est|c'est)\s+le)\s+(\d{1,2}(?:er)?\s+[a-zéûôî]+(?:\s+\d{4})?)"#),
        ]
        return patterns.compactMap { (key, pattern) in
            // caseInsensitive : sans lui, "je suis né le 15 Mai 1990" ne matchait pas ([a-zéûôî]
            // refusait le M majuscule du mois).
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (key, $0) }
        }
    }()

    /// Garde-fou du pattern "je suis X" : premier mot qui prouve que X n'est PAS un prénom
    /// ("je suis d'accord", "en retard", "fatigué", "développeur", "né"…). Comparaison
    /// normalisée (minuscules, sans accents ni apostrophes) + rejet des tokens à chiffres.
    /// Un faux négatif coûte juste une popup de moins ; un faux positif ne coûte qu'une popup.
    private static let nameValueExclusions: Set<String> = [
        "en", "a", "au", "aux", "chez", "dans", "avec", "sans", "pour", "par", "sous",
        "entre", "de", "du", "des", "le", "la", "les", "un", "une", "ce", "cette",
        "mon", "ma", "mes", "ton", "ta", "son", "sa",
        "et", "ou", "mais", "donc", "or", "ni", "car",
        "tres", "trop", "si", "tout", "toute", "tous", "toutes", "plus", "moins",
        "bien", "mal", "vraiment", "aussi", "encore", "deja", "toujours", "jamais", "ici",
        "daccord", "ok", "okay", "ko", "chaud", "partant", "partante", "preneur",
        "sur", "sure", "certain", "certaine", "desole", "desolee", "fatigue", "fatiguee",
        "malade", "perdu", "perdue", "pret", "prete", "ne", "nee",
        "content", "contente", "heureux", "heureuse", "triste", "enerve", "enervee",
        "presse", "pressee", "stresse", "stressee", "fou", "folle", "bete",
        "debout", "assis", "assise", "couche", "leve", "levee", "rentre", "rentree",
        "sorti", "sortie", "parti", "partie", "reste", "restee", "creve", "crevee",
        "claque", "claquee", "occupe", "occupee", "dispo", "disponible",
        "marie", "mariee", "celibataire", "veuf", "veuve", "mort", "morte",
        "rouge", "vert", "bleu", "pale", "large", "naze",
        "dev", "developpeur", "developpeuse", "ingenieur", "medecin", "infirmier",
        "infirmiere", "prof", "professeur", "etudiant", "etudiante", "eleve",
        "avocat", "avocate", "comptable", "commercial", "commerciale", "manager",
        "artisan", "agriculteur", "chauffeur", "cuisinier", "cuisiniere", "serveur",
        "serveuse", "coiffeur", "coiffeuse", "mecanicien", "electricien", "plombier",
        "architecte", "designer", "journaliste", "photographe", "artiste", "musicien",
        "musicienne", "acteur", "actrice", "ecrivain", "chercheur", "scientifique",
        "militaire", "policier", "policiere", "pompier", "pilote", "hote", "hotesse",
        "secretaire", "assistante", "retraite", "stagiaire", "freelance", "chomeur",
        "patron", "chef", "employe", "ouvrier", "cadre", "fonctionnaire", "commercant",
        "boulanger", "marin", "soldat", "benevole",
        "papa", "maman", "pere", "mere", "fils", "fille", "frere", "soeur",
        "oncle", "tante", "cousin", "cousine",
    ]

    /// Mots qui ne terminent jamais un prénom : "je suis Dimitri et toi" capture
    /// "Dimitri et" — on élague pour garder "Dimitri". Normalisés comme les exclusions.
    private static let nameTrailingStoppers: Set<String> = [
        "et", "ou", "mais", "donc", "or", "ni", "car",
        "avec", "sans", "pour", "par", "dans", "sur", "sous", "chez",
        "de", "du", "des", "le", "la", "les", "un", "une",
        "qui", "que", "quoi", "dont", "quand", "comment",
        "aussi", "egalement", "vraiment", "tres", "trop", "bien", "encore", "deja",
        "toujours", "ici", "y", "en", "a", "au", "est", "suis",
        "il", "elle", "ils", "elles", "je", "tu", "nous", "vous",
        "mon", "ma", "mes", "ton", "ta", "son", "sa", "ce", "cette", "ces",
        "toi", "moi", "lui", "eux",
    ]

    nonisolated static func normalizeNameToken(_ token: some StringProtocol) -> String {
        var norm = token.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        norm = norm.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        return norm
    }

    nonisolated static func isExcludedNameValue(_ value: String) -> Bool {
        guard let first = value.split(separator: " ").first else { return true }
        let norm = normalizeNameToken(first)
        if norm.rangeOfCharacter(from: .decimalDigits) != nil { return true }
        return nameValueExclusions.contains(norm)
    }

    nonisolated static func trimNameTrailingStoppers(_ value: String) -> String {
        var tokens = value.split(separator: " ").map(String.init)
        while tokens.count > 1, nameTrailingStoppers.contains(normalizeNameToken(tokens.last!)) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    func extract(from text: String) -> [(key: String, value: String)] {
        var found: [(String, String)] = []
        for (key, regex) in Self.factPatterns {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text)
            else { continue }
            var value = String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if key == "user.name" {
                // "je suis Dimitri et toi" capture "Dimitri et" : on élague le mot de liaison.
                value = Self.trimNameTrailingStoppers(value)
                // Le pattern large "je suis X" capte aussi des états/métiers ("d'accord",
                // "fatigué", "développeur") : on écarte ces faux positifs AVANT la popup.
                if value.isEmpty || Self.isExcludedNameValue(value) { continue }
            }
            found.append((key, value))
        }
        return found
    }
}
