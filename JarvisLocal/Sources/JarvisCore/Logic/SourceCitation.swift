import Foundation

/// Citation des sources web, extraite à l'identique depuis AppViewModel.
/// Fonctions pures — le ViewModel garde des forwarders.
public enum SourceCitation {
    public static func extractSourceURLs(from toolResult: String) -> [String] {
        toolResult.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("Source : ") else { return nil }
            let url = String(trimmed.dropFirst("Source : ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return url.hasPrefix("http") ? url : nil
        }
    }

    public static func appendMissingSources(to text: String, sources: [String]) -> String {
        var seen: [String] = []
        for s in sources where !seen.contains(s) { seen.append(s) }
        guard !seen.isEmpty,
              !text.contains("http"),
              !text.localizedCaseInsensitiveContains("source") else { return text }
        return text + "\n\nSources :\n" + seen.map { "- \($0)" }.joined(separator: "\n")
    }

    public static func stripSavedSourcesTrailer(from text: String) -> String {
        guard let r = text.range(of: "\n\nSources :\n", options: .backwards) else { return text }
        let tail = text[r.upperBound...].components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !tail.isEmpty,
              tail.allSatisfy({ $0.hasPrefix("- http") })
        else { return text }
        return String(text[..<r.lowerBound])
    }
}
