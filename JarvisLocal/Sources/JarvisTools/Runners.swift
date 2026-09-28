import Foundation

/// L2 — exécution réelle vs simulée : chaque outil à effet de bord passe par
/// un runner injecté. Prod = live, tests = fake, eval = fake ou live
/// lecture-seule. Tout outil qui écrit ou envoie est ainsi testable sans
/// effet réel.
public protocol AppleScriptRunner: Sendable {
    func run(script: String) async throws -> String
}

public struct LiveAppleScriptRunner: AppleScriptRunner {
    public init() {}

    public func run(script: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolRunnerError.failed("osascript code \(process.terminationStatus)")
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

public struct FakeAppleScriptRunner: AppleScriptRunner {
    public var canned: [String: String]
    public private(set) var received: [String] = []

    public init(canned: [String: String] = [:]) {
        self.canned = canned
    }

    public func run(script: String) async throws -> String {
        for (needle, answer) in canned where script.lowercased().contains(needle) {
            return answer
        }
        return "AppleScript exécuté (simulé)."
    }
}

public protocol URLOpener: Sendable {
    func open(target: String) async throws -> String
}

/// Ouvre via `/usr/bin/open` (pas d'AppKit dans le moteur).
public struct LiveURLOpener: URLOpener {
    public init() {}

    public func open(target: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [target]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolRunnerError.failed("open code \(process.terminationStatus)")
        }
        return "Ouvert : \(target)."
    }
}

public struct FakeURLOpener: URLOpener {
    public init() {}

    public func open(target: String) async throws -> String {
        "Ouvert (simulé) : \(target)."
    }
}

public protocol Screenshotter: Sendable {
    func capture() async throws -> Data
}

public struct LiveScreenshotter: Screenshotter {
    public init() {}

    public func capture() async throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-shot-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolRunnerError.failed("screencapture code \(process.terminationStatus)")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }
}

public struct FakeScreenshotter: Screenshotter {
    public init() {}

    public func capture() async throws -> Data {
        // PNG 1×1 minimal valide (déterministe, sans permission écran).
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
}

public protocol Clipboard: Sendable {
    func get() async -> String
    func set(_ text: String) async throws
}

/// Presse-papiers via `pbpaste`/`pbcopy` (pas d'AppKit dans le moteur).
public struct LiveClipboard: Clipboard {
    public init() {}

    public func get() async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    public func set(_ text: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()
        pipe.fileHandleForWriting.write(Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

public struct FakeClipboard: Clipboard {
    public var content: String

    public init(content: String = "") {
        self.content = content
    }

    public func get() async -> String { content }

    public func set(_ text: String) async throws {}
}

public protocol Notifier: Sendable {
    func notify(message: String) async throws
}

public struct LiveNotifier: Notifier {
    public init() {}

    public func notify(message: String) async throws {
        _ = try await LiveAppleScriptRunner().run(
            script: "display notification \"\(message.replacingOccurrences(of: "\"", with: "'"))\" with title \"Jarvis\"")
    }
}

public struct FakeNotifier: Notifier {
    public init() {}

    public func notify(message: String) async throws {}
}

public enum ToolRunnerError: Error, Sendable, Equatable {
    case failed(String)
}
