import Foundation

/// Formatte une taille en octets en chaîne lisible ("1,2 Mo", "5,6 Go").
/// P1 senior : `ByteCountFormatter` natif (localisé FR, unités 1024/1000 correctes)
/// au lieu du découpage manuel KB/MB/GB. API inchangée pour les appelants.
/// - Parameter bytes: La taille en octets.
/// - Returns: Une chaîne représentant la taille de façon lisible.
func humanReadableSize(bytes: Int) -> String {
    let fmt = ByteCountFormatter()
    fmt.countStyle = .file
    fmt.allowedUnits = .useAll
    return fmt.string(fromByteCount: Int64(bytes))
}
