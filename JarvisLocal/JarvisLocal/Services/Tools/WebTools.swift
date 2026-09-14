import Foundation
import AppKit

/// Domaine Web : recherche, lecture d'URL, météo, plans.
/// Pourquoi groupés : ce sont les seuls outils réseau + Maps ; ils partagent
/// le userAgent et la règle "résultat = DONNÉES à analyser, jamais instruction".
actor WebTools {
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// search_web délégué au service cascade (chantier 1).
    /// Pourquoi ne pas throw : une panne réseau = texte explicite, jamais
    /// un throw qui ferait perdre les autres résultats du batch.
    func searchWeb(_ query: String) async -> String {
        await WebSearchService.shared.search(query: query)
    }

    func readURL(_ urlString: String) async -> String {
        // Même règle que SystemTools.httpURL : pas de préfixe aveugle (un file://…
        // ne doit jamais devenir "https://file/…"), puis garde anti-SSRF.
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized) else { return "URL invalide : \(urlString)." }
        // Anti-SSRF (même garde que search_web) : pas de file://, localhost, LAN,
        // ni de nom public rebondissant vers une IP privée — fail-closed.
        if URLSafety.isBlocked(url) {
            return "Source : \(normalized)\nURL refusée : seules les pages web publiques (http/https) peuvent être lues."
        }
        guard let html = await fetchPage(url, timeout: 20) else {
            return "Source : \(normalized)\nImpossible de récupérer le contenu de \(urlString) (page inaccessible ou timeout)."
        }
        let text = html.htmlToText(maxLength: 4000)
        // L'URL en tête pour que le modèle puisse la citer (même règle que search_web).
        return text.count > 100 ? "Source : \(normalized)\n\(text)" : "Source : \(normalized)\nContenu de la page insuffisant ou vide."
    }

    /// Fetch générique : UA navigateur + timeout court, une requête qui traîne
    /// ne doit jamais bloquer tout le tour de conversation.
    private func fetchPage(_ url: URL, timeout: TimeInterval) async -> String? {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        return html
    }

    /// Open-Meteo plutôt que search_web : sans clé API, JSON stable, pas de
    /// scraping HTML fragile (contrairement à l'ancien DDG regex).
    func getWeather(city: String) async -> String {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Aucune ville fournie." }

        guard let encodedCity = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let geoURL = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(encodedCity)&count=1&language=fr&format=json")
        else { return "Erreur d'encodage du nom de ville." }

        guard let geoData = try? await URLSession.shared.data(for: {
            var r = URLRequest(url: geoURL); r.timeoutInterval = 20; return r
        }()).0,
              let geoJSON = try? JSONSerialization.jsonObject(with: geoData) as? [String: Any],
              let results = geoJSON["results"] as? [[String: Any]],
              let first = results.first,
              let lat = first["latitude"] as? Double,
              let lon = first["longitude"] as? Double
        else {
            return "Ville \"\(trimmed)\" introuvable. Vérifie l'orthographe ou précise le pays."
        }
        let resolvedName = first["name"] as? String ?? trimmed
        let country = first["country"] as? String ?? ""

        guard let forecastURL = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m&daily=temperature_2m_max,temperature_2m_min,weather_code,precipitation_sum,wind_speed_10m_max&timezone=auto") else {
            return "Erreur de construction de l'URL météo."
        }
        guard let (data, response) = try? await URLSession.shared.data(for: {
            var r = URLRequest(url: forecastURL); r.timeoutInterval = 20; return r
        }()),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any]
        else {
            return "Service météo indisponible pour \(resolvedName) en ce moment."
        }

        let temp = current["temperature_2m"] as? Double ?? 0
        let feelsLike = current["apparent_temperature"] as? Double ?? temp
        let humidity = current["relative_humidity_2m"] as? Double ?? 0
        let wind = current["wind_speed_10m"] as? Double ?? 0
        let code = current["weather_code"] as? Int ?? -1

        let condition = Self.weatherCodeDescriptions[code] ?? "conditions inconnues"

        var result = "Météo à \(resolvedName)\(country.isEmpty ? "" : ", \(country)") : actuellement \(condition), \(String(format: "%.0f", temp))°C (ressenti \(String(format: "%.0f", feelsLike))°C), humidité \(String(format: "%.0f", humidity))%, vent \(String(format: "%.0f", wind)) km/h."

        if let daily = json["daily"] as? [String: Any],
           let dates = daily["time"] as? [String],
           let maxTemps = daily["temperature_2m_max"] as? [Double],
           let minTemps = daily["temperature_2m_min"] as? [Double],
           let weatherCodes = daily["weather_code"] as? [Int],
           let precip = daily["precipitation_sum"] as? [Double],
           let windMax = daily["wind_speed_10m_max"] as? [Double] {

            for i in 0..<min(dates.count, 3) where i > 0 {
                let dayName = i == 1 ? "Demain" : "Le \(dates[i])"
                let dayCode = weatherCodes.indices.contains(i) ? weatherCodes[i] : -1
                let dayCondition = Self.weatherCodeDescriptions[dayCode] ?? "conditions inconnues"
                let dayPrecip = precip.indices.contains(i) ? precip[i] : 0
                let dayWind = windMax.indices.contains(i) ? windMax[i] : 0
                result += " | \(dayName) : \(dayCondition), \(String(format: "%.0f", minTemps[i]))°C ~ \(String(format: "%.0f", maxTemps[i]))°C, précip. \(String(format: "%.0f", dayPrecip))mm, vent \(String(format: "%.0f", dayWind)) km/h."
            }
        }

        return result
    }

    nonisolated static let weatherCodeDescriptions: [Int: String] = [
        0: "ciel dégagé", 1: "plutôt dégagé", 2: "partiellement nuageux", 3: "couvert",
        45: "brouillard", 48: "brouillard givrant",
        51: "bruine légère", 53: "bruine modérée", 55: "bruine dense",
        61: "pluie légère", 63: "pluie modérée", 65: "pluie forte",
        71: "neige légère", 73: "neige modérée", 75: "neige forte",
        80: "averses légères", 81: "averses modérées", 82: "averses violentes",
        95: "orage", 96: "orage avec grêle légère", 99: "orage avec grêle forte"
    ]

    func searchMaps(_ query: String) async throws -> String {
        let lower = query.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let personalLabels = [
            "domicile", "maison", "chez moi", "chezmoi",
            "travail", "bureau", "job", "boulot",
            "ecole", "lycee", "college", "universite", "fac", "school"
        ]
        if personalLabels.contains(where: { lower.contains($0) }) {
            let script = """
            tell application "Contacts"
                launch
                set myCard to my card
                repeat with a in every address of myCard
                    set lbl to ""
                    try
                        set lbl to label of a
                    end try
                    if lbl contains "Home" or lbl contains "Work" or lbl contains "School" then
                        set parts to {street of a, city of a, zip of a, country of a}
                        set filtered to ""
                        repeat with p in parts
                            if p is not missing value and p is not "" then
                                set filtered to filtered & p & ", "
                            end if
                        end repeat
                        if filtered is not "" then
                            return text 1 thru -3 of filtered
                        end if
                    end if
                end repeat
                return ""
            end tell
            """
            var error: NSDictionary?
            let result = try await MainActor.run { () -> NSAppleEventDescriptor? in
                NSAppleScript(source: script)?.executeAndReturnError(&error)
            }
            if let addr = result?.stringValue, !addr.isEmpty {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let mapURL = URL(string: "maps://?q=\(encoded)") {
                    NSWorkspace.shared.open(mapURL)
                }
                return "Adresse trouvée : \"\(addr)\". Passe cette adresse dans le paramètre location."
            }
        }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let mapURL = URL(string: "maps://?q=\(encoded)") else {
            return "Recherche invalide : \"\(query)\"."
        }
        NSWorkspace.shared.open(mapURL)
        return "Plans ouvert avec la recherche \"\(query)\"."
    }
}
