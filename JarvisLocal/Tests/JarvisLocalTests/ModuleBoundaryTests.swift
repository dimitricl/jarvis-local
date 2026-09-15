import XCTest

/// Garde-fous de la frontière de couches (étape 1) : ces tests échouent dès que
/// la séparation se dégrade — sans attendre une revue humaine.
///
/// Localisation repo : `#filePath` → Tests/JarvisLocalTests/ModuleBoundaryTests.swift,
/// on remonte de 3 crans (fichier → JarvisLocalTests → Tests → racine package).
final class ModuleBoundaryTests: XCTestCase {
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // ModuleBoundaryTests.swift
        url.deleteLastPathComponent() // JarvisLocalTests
        url.deleteLastPathComponent() // Tests
        return url // JarvisLocal/ (racine package : Package.swift + Sources/)
    }

    private func swiftFiles(under dir: String) -> [URL] {
        let base = packageRoot.appendingPathComponent(dir)
        var out: [URL] = []
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
            return out
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Coupe les commentaires `//` de fin de ligne avant le scan.
    /// Limite documentée : un token placé APRÈS un `//` sur la même ligne
    /// (ex. dans un littéral URL "https://…") est ignoré — les tokens surveillés
    /// sont des noms de types CamelCase qui n'apparaissent jamais à cet endroit.
    private func codeOnly(_ content: String) -> String {
        content.components(separatedBy: "\n").map { line in
            if let idx = line.range(of: "//")?.lowerBound { return String(line[..<idx]) }
            return line
        }.joined(separator: "\n")
    }

    /// JarvisUI ne doit nommer aucun concret de JarvisServices : ni import du
    /// module, ni SQLite, ni singletons. Le graphe Package.swift l'interdit déjà
    /// (pas d'arête JarvisUI → JarvisServices) ; ce test le prouve au niveau source.
    func testJarvisUIDoesNotReferenceServices() throws {
        let forbidden = [
            "JarvisServices", "SQLite3", "sqlite3_",
            "DatabaseService", "OllamaService", "ToolService",
            "MCPToolProvider", "MCPServerConfig", "WebSearchService",
            "AudioService", "STTService", "ServiceHosts", "Settings.shared",
        ]
        let files = swiftFiles(under: "Sources/JarvisUI")
        XCTAssertFalse(files.isEmpty, "Sources/JarvisUI introuvable depuis \(packageRoot.path)")
        var violations: [String] = []
        for file in files {
            let code = codeOnly(try String(contentsOf: file, encoding: .utf8))
            for token in forbidden where code.contains(token) {
                violations.append("\(file.lastPathComponent) : contient « \(token) »")
            }
        }
        XCTAssertTrue(violations.isEmpty, "Frontière JarvisUI violée :\n" + violations.joined(separator: "\n"))
    }

    /// JarvisCore : models + protocols purs. Aucun import UI (SwiftUI/AppKit),
    /// persistance (SQLite3), réseau/parsing (SwiftSoup/Network) ou services
    /// système (EventKit/Speech/AVFoundation/ServiceManagement).
    func testJarvisCoreHasNoUIDBOrNetworkDependencies() throws {
        let forbidden = [
            "import SwiftUI", "import AppKit", "import SQLite3", "import SwiftSoup",
            "import EventKit", "import Speech", "import AVFoundation",
            "import ServiceManagement", "import Network", "import UserNotifications",
        ]
        let files = swiftFiles(under: "Sources/JarvisCore")
        XCTAssertFalse(files.isEmpty, "Sources/JarvisCore introuvable depuis \(packageRoot.path)")
        var violations: [String] = []
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden where content.contains(token) {
                violations.append("\(file.lastPathComponent) : contient « \(token) »")
            }
        }
        XCTAssertTrue(violations.isEmpty, "JarvisCore pollué :\n" + violations.joined(separator: "\n"))
    }

    /// `@_exported import` réexporterait un module à travers la frontière
    /// (ex. JarvisUI réexportant JarvisServices) : interdit partout.
    /// NOTE : ce fichier lui-même nomme le motif (dans ce commentaire et dans
    /// le code de scan) — il est donc exclu du scan, sinon le test se détecte.
    func testNoExportedImports() throws {
        var violations: [String] = []
        for dir in ["Sources", "Tests"] {
            for file in swiftFiles(under: dir) {
                guard file.lastPathComponent != "ModuleBoundaryTests.swift" else { continue }
                let content = try String(contentsOf: file, encoding: .utf8)
                if codeOnly(content).contains("@_exported") {
                    violations.append(file.path.replacingOccurrences(of: packageRoot.path + "/", with: ""))
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, "@_exported détecté (frontière trouée) :\n" + violations.joined(separator: "\n"))
    }

    /// La target JarvisUI déclare JarvisCore comme seule dépendance inter-module :
    /// jamais JarvisServices directement. Vérifié en parsant le bloc `.target(...)`
    /// de Package.swift (comptage de parenthèses, pas de heuristique fragile).
    func testJarvisUITargetDependsOnCoreOnly() throws {
        let packageFile = packageRoot.appendingPathComponent("Package.swift")
        let content = try String(contentsOf: packageFile, encoding: .utf8)
        let block = try targetBlock(named: "JarvisUI", in: content)
        XCTAssertTrue(block.contains("\"JarvisCore\""), "JarvisUI doit dépendre de JarvisCore")
        XCTAssertFalse(block.contains("\"JarvisServices\""), "JarvisUI ne doit JAMAIS dépendre de JarvisServices")
    }

    private func targetBlock(named name: String, in content: String) throws -> String {
        guard let nameRange = content.range(of: "name: \"\(name)\"") else {
            throw XCTSkip("target \(name) introuvable dans Package.swift")
        }
        let prefix = content[..<nameRange.lowerBound]
        let kinds = [".target(", ".executableTarget(", ".testTarget("]
        var targetStart: String.Index?
        for kind in kinds {
            if let r = prefix.range(of: kind, options: .backwards) {
                if targetStart == nil || r.lowerBound > targetStart! { targetStart = r.lowerBound }
            }
        }
        guard let start = targetStart else { throw XCTSkip("déclaration de target introuvable") }
        var depth = 0
        var end = content.endIndex
        var cursor = start
        var inString = false
        var prev: Character = "\0"
        while cursor < content.endIndex {
            let ch = content[cursor]
            if ch == "\"" && prev != "\\" { inString.toggle() }
            if !inString {
                if ch == "(" { depth += 1 }
                if ch == ")" {
                    depth -= 1
                    if depth == 0 { end = content.index(after: cursor); break }
                }
            }
            prev = ch
            cursor = content.index(after: cursor)
        }
        return String(content[start..<end])
    }
}
