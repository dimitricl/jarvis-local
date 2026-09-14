/// Formats a file size in bytes into a human-readable string (e.g., "1.2 KB", "5.6 MB").
/// - Parameter bytes: The size in bytes.
/// - Returns: A string representing the size in a human-readable format.
func humanReadableSize(bytes: Int) -> String {
    let kb: Double = Double(bytes) / 1024
    if kb < 1 {
        return "\(bytes) B"
    }

    let mb: Double = kb / 1024
    if mb < 1 {
        return String(format: "%.1f KB", kb)
    }

    let gb: Double = mb / 1024
    if gb < 1 {
        return String(format: "%.1f MB", mb)
    }

    let tb: Double = gb / 1024
    if tb < 1 {
        return String(format: "%.1f GB", gb)
    }

    return String(format: "%.1f TB", tb)
}
