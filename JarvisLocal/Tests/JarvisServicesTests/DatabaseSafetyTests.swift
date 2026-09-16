@testable import JarvisServices
import XCTest

/// Filet post-incident "conversations volatilisées" :
/// - backup horodaté AVANT toute migration (données + -wal + -shm) ;
/// - rétention : 3 plus récents ;
/// - journal os_log des suppressions (Console.app, catégorie database).
/// La journalisation elle-même n'est pas assertable : ces tests couvrent le
/// backup (déclenchement, nommage, rétention, préservation des données).
final class DatabaseSafetyTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func backups(in dir: URL) throws -> [String] {
        // Fichiers principaux uniquement (pas les sidecars -wal/-shm).
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter {
            $0.hasPrefix("memory.backup.") && $0.hasSuffix(".db")
        }
    }

    func testBackupCreatedBeforeMigration() async throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("memory.db").path
        let db = DatabaseService.shared
        try await db.open(path: path) // base neuve -> v3 direct, aucun backup
        XCTAssertTrue(try backups(in: dir).isEmpty, "base neuve : aucun backup attendu")

        try await db.upsertFact(key: "k", value: "v")
        try await db.setUserVersion(2) // simule une base à migrer
        try await db.open(path: path) // sonde v2 -> backup -> migration v3
        let version = try await db.userVersion()
        XCTAssertEqual(version, 3)
        let found = try backups(in: dir)
        XCTAssertEqual(found.count, 1, "un backup horodaté attendu, obtenu : \(found)")
        XCTAssertTrue(found[0].contains(".v2."), "le tag de version d'origine doit figurer : \(found[0])")
        // Données préservées à travers backup + migration.
        let kept = try await db.getFact(key: "k")
        XCTAssertNotNil(kept)
    }

    func testNoBackupWhenAlreadyCurrent() async throws {
        let dir = try tempDir()
        let path = dir.appendingPathComponent("memory.db").path
        let db = DatabaseService.shared
        try await db.open(path: path)
        try await db.open(path: path) // déjà v3 -> rien à sauvegarder
        XCTAssertTrue(try backups(in: dir).isEmpty)
    }

    func testBackupTimestampIsUTCAndSortable() {
        XCTAssertEqual(DatabaseService.backupTimestamp(for: Date(timeIntervalSince1970: 0)), "19700101-000000")
    }

    func testPruneBackupsKeepsLatestThree() throws {
        let dir = try tempDir()
        let fm = FileManager.default
        for day in ["01", "02", "03", "04", "05"] {
            _ = fm.createFile(atPath: dir.appendingPathComponent("memory.backup.v2.202401\(day)-000000.db").path, contents: Data())
            _ = fm.createFile(atPath: dir.appendingPathComponent("memory.backup.v2.202401\(day)-000000.db-wal").path, contents: Data())
        }
        try DatabaseService.pruneBackups(in: dir)
        let remaining = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(remaining.filter { $0.hasSuffix(".db") }.count, 3)
        XCTAssertFalse(remaining.contains { $0.contains("20240101") || $0.contains("20240102") })
        XCTAssertTrue(remaining.contains { $0.contains("20240105") })
        // Les -wal des survivants sont conservés, ceux des purgés supprimés.
        XCTAssertTrue(remaining.contains("memory.backup.v2.20240105-000000.db-wal"))
        XCTAssertFalse(remaining.contains("memory.backup.v2.20240101-000000.db-wal"))
    }
}
