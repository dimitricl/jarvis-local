@testable import JarvisServices
import XCTest
import Foundation

/// Tâche 3 — read_file / list_directory sandboxés : même logique fail-closed
/// que URLSafety.isBlocked pour read_url (refus explicite, jamais de devinette),
/// plafond 200 Ko comme WebTools.maxPageBytes, binaires refusés (pas de mojibake).
/// Style des cas de refus calqué sur SecurityGuardsTests (boucles de refus).
final class FileToolsTests: XCTestCase {
    // MARK: - Refus (fail-closed, sans FS requis)

    func testBlockedPathsRefused() async {
        // Chemins qui doivent TOUS être refusés : hors sandbox, inexistant, vide.
        for raw in ["/etc/passwd", "/tmp", "/var/log/system.log", "/",
                    "/Users/nonexistent-user-12345/Documents",
                    "~/Documents/../../..", "~/../Library",
                    "", "   "] as [String] {
            let listed = await FileTools().listDirectory(path: raw)
            XCTAssertTrue(listed.contains("refusé"),
                          "list_directory aurait dû refuser « \(raw) » : \(listed)")
            let read = await FileTools().readFile(path: raw)
            XCTAssertTrue(read.contains("refusé"),
                          "read_file aurait dû refuser « \(raw) » : \(read)")
        }
    }

    func testDotDotEscapeRefusedEvenWhenItExists() async {
        // ".." qui RESOUT hors sandbox (existe réellement) : refusé après
        // résolution canonique, comme un symlink qui sortirait des racines.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let escape = home + "/Documents/../../../../etc"
        let listed = await FileTools().listDirectory(path: escape)
        XCTAssertTrue(listed.contains("refusé"), "évasion .. non refusée : \(listed)")
    }

    func testIsBlockedPureLogic() {
        let home = URL(fileURLWithPath: "/Users/testuser")
        let roots = FileTools.allowedRoots(home: home)
        XCTAssertEqual(roots.count, 3)
        // Dedans : accepté.
        XCTAssertFalse(FileTools.isBlocked(URL(fileURLWithPath: "/Users/testuser/Documents/a.txt"), roots: roots))
        XCTAssertFalse(FileTools.isBlocked(URL(fileURLWithPath: "/Users/testuser/Desktop"), roots: roots))
        // Préfixe piégé (…/Documents-piege) : refusé — comparaison par segment, pas hasPrefix brut.
        XCTAssertTrue(FileTools.isBlocked(URL(fileURLWithPath: "/Users/testuser/Documents-piege"), roots: roots))
        XCTAssertTrue(FileTools.isBlocked(URL(fileURLWithPath: "/Users/testuser/DocumentsBackup/x"), roots: roots))
        // Dehors : refusé.
        XCTAssertTrue(FileTools.isBlocked(URL(fileURLWithPath: "/etc/passwd"), roots: roots))
        XCTAssertTrue(FileTools.isBlocked(URL(fileURLWithPath: "/tmp/x"), roots: roots))
    }

    func testCanonicalRejectsEmptyAndMissing() {
        XCTAssertNil(FileTools.canonical(""))
        XCTAssertNil(FileTools.canonical("   "))
        XCTAssertNil(FileTools.canonical("~/Documents/jarvis-test-inexistant-12345.txt"))
    }

    // MARK: - Rondes positives + plafond + binaire (dans ~/Documents, nettoyées)

    private func sandboxDir() throws -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("JarvisLocalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: base)
        }
        return base
    }

    func testReadWriteRoundTripCitesSource() async throws {
        let dir = try sandboxDir()
        let file = dir.appendingPathComponent("hello.txt")
        try "Bonjour Jarvis".write(to: file, atomically: true, encoding: .utf8)

        let listed = await FileTools().listDirectory(path: dir.path)
        XCTAssertTrue(listed.contains("hello.txt"), listed)

        let read = await FileTools().readFile(path: file.path)
        XCTAssertTrue(read.contains("Source : \(file.path)"), read)
        XCTAssertTrue(read.contains("Bonjour Jarvis"), read)
    }

    func testTildePathsAccepted() async throws {
        let dir = try sandboxDir()
        let file = dir.appendingPathComponent("tilde.txt")
        try "tilde ok".write(to: file, atomically: true, encoding: .utf8)
        // Même fichier via "~" : accepté après expansion.
        let docs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents").path
        _ = docs
        let relative = "~/" + file.path
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/", with: "")
        let read = await FileTools().readFile(path: relative)
        XCTAssertTrue(read.contains("tilde ok"), read)
    }

    func testBinaryFileRefusedNotMojibake() async throws {
        let dir = try sandboxDir()
        let file = dir.appendingPathComponent("blob.bin")
        // Octets invalides en UTF-8 (continuation sans début, surrogates bruts).
        try Data([0xFF, 0xFE, 0x00, 0x28, 0x89, 0x50, 0x4E, 0x47]).write(to: file)
        let read = await FileTools().readFile(path: file.path)
        XCTAssertTrue(read.contains("refusé"), read)
        XCTAssertTrue(read.contains("pas un fichier texte"), read)
    }

    func testLargeFileTruncatedAt200Ko() async throws {
        let dir = try sandboxDir()
        let file = dir.appendingPathComponent("gros.txt")
        let big = String(repeating: "a", count: FileTools.maxFileBytes + 50_000)
        try big.write(to: file, atomically: true, encoding: .utf8)
        let read = await FileTools().readFile(path: file.path)
        XCTAssertTrue(read.contains("tronqué"), read)
        XCTAssertTrue(read.utf8.count <= FileTools.maxFileBytes + 1_000, "plafond dépassé : \(read.utf8.count)")
    }

    func testMaxFileBytesIs200Ko() {
        XCTAssertEqual(FileTools.maxFileBytes, 200_000)
    }

    func testListDirectoryOnFileRefused() async throws {
        let dir = try sandboxDir()
        let file = dir.appendingPathComponent("f.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let listed = await FileTools().listDirectory(path: file.path)
        XCTAssertTrue(listed.contains("n'est pas un dossier"), listed)
    }

    func testReadFileOnDirectoryRefused() async throws {
        let dir = try sandboxDir()
        let read = await FileTools().readFile(path: dir.path)
        XCTAssertTrue(read.contains("n'est pas un fichier"), read)
    }
}
