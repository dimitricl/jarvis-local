@testable import JarvisServices
import XCTest

/// Filet recovery : une base fichier illisible/corrompue ne rend plus l'app
/// inutilisable — fichiers mis à l'écart (quarantaine horodatée, jamais
/// supprimés) puis réouverture d'une base neuve en v3.
final class DatabaseRecoveryTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testCorruptFileQuarantinedAndFreshDBOpened() async throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("memory.db").path
        // Fichier garbage : pas une base SQLite.
        try Data("ceci n'est pas une base sqlite".utf8).write(to: URL(fileURLWithPath: path))
        // Sidecar factice pour vérifier le déplacement groupé.
        _ = FileManager.default.createFile(atPath: path + "-wal", contents: Data("wal".utf8))

        let db = DatabaseService.shared
        try await db.open(path: path) // ne doit pas throw : recovery + base neuve

        let version = try await db.userVersion()
        XCTAssertEqual(version, DatabaseService.currentSchemaVersion)
        // Base neuve utilisable.
        _ = try await db.createConversation(title: "Après recovery")

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("memory.corrupt.") && $0.hasSuffix(".db") },
                      "quarantaine attendue, fichiers : \(files)")
        XCTAssertTrue(files.contains { $0.hasPrefix("memory.corrupt.") && $0.hasSuffix(".db-wal") },
                      "le sidecar -wal doit suivre en quarantaine, fichiers : \(files)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "une base neuve doit exister au chemin d'origine")
    }

    func testQuarantineReturnsNilWhenNothingToMove() throws {
        let dir = try tempDir()
        let missing = dir.appendingPathComponent("memory.db").path
        let got = try DatabaseService.quarantineCorruptDB(at: missing)
        XCTAssertNil(got, "aucun fichier → nil, pas d'erreur")
    }

    func testHealthyDBNeverQuarantined() async throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("memory.db").path
        let db = DatabaseService.shared
        try await db.open(path: path)
        try await db.open(path: path) // réouverture saine : pas de recovery
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(files.contains { $0.hasPrefix("memory.corrupt.") },
                       "aucune quarantaine sur base saine, fichiers : \(files)")
    }
}
