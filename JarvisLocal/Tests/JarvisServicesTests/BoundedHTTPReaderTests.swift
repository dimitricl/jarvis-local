@testable import JarvisServices
import XCTest
import Foundation

/// Tests du lecteur HTTP borné : AUCUN réseau réel (URLProtocol simulé).
/// Chaque test vérifie l'ARRÊT de la lecture (chunks non envoyés / cancel),
/// pas seulement le texte retourné.
final class BoundedHTTPReaderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BoundedMockProtocol.reset()
    }

    private func mockConfig() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [BoundedMockProtocol.self]
        return c
    }

    private func request() -> URLRequest {
        var r = URLRequest(url: URL(string: "https://example.com/page")!)
        r.timeoutInterval = 10
        return r
    }

    // Réponse > plafond SANS Content-Length : bornée + tâche annulée.
    func testOversizedWithoutContentLengthTruncatesAndCancels() async throws {
        let chunk = Data(repeating: 0x41, count: 50) // 50 x "A"
        BoundedMockProtocol.stub = .init(
            status: 200,
            headers: ["Content-Type": "text/html"], // pas de Content-Length
            chunks: Array(repeating: chunk, count: 20) // 1000 octets dispo
        )
        let res = try await BoundedHTTPReader.fetch(
            request: request(), maxBytes: 200, sessionConfiguration: mockConfig()
        )
        XCTAssertEqual(res.data.count, 200)
        XCTAssertTrue(res.truncated)
        // ARRÊT réel : le flux est gelé après le plafond (cancel explicite de
        // la dataTask dans le lecteur). On attend que d'éventuels chunks en vol
        // se stabilisent, puis on vérifie que rien de plus n'a circulé.
        let sentAtReturn = BoundedMockProtocol.sentChunks
        XCTAssertLessThan(sentAtReturn, BoundedMockProtocol.totalChunks)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(BoundedMockProtocol.sentChunks, sentAtReturn)
        XCTAssertLessThan(BoundedMockProtocol.sentChunks, BoundedMockProtocol.totalChunks)
    }

    // Content-Length mensonger (petit) + gros corps : le streaming protège seul.
    func testLyingContentLengthDoesNotBypassStreamingCap() async throws {
        let chunk = Data(repeating: 0x42, count: 100)
        BoundedMockProtocol.stub = .init(
            status: 200,
            headers: ["Content-Type": "text/html", "Content-Length": "10"],
            chunks: Array(repeating: chunk, count: 10) // 1000 octets réels
        )
        let res = try await BoundedHTTPReader.fetch(
            request: request(), maxBytes: 200, sessionConfiguration: mockConfig()
        )
        XCTAssertEqual(res.data.count, 200)
        XCTAssertTrue(res.truncated)
        let sentAtReturn = BoundedMockProtocol.sentChunks
        XCTAssertLessThan(sentAtReturn, BoundedMockProtocol.totalChunks)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(BoundedMockProtocol.sentChunks, sentAtReturn)
    }

    // Binaire avéré : refusé sur les headers, corps jamais consommé en entier.
    func testBinaryMIMERefusedBeforeBody() async throws {
        BoundedMockProtocol.stub = .init(
            status: 200,
            headers: ["Content-Type": "image/png"],
            chunks: Array(repeating: Data(repeating: 0x89, count: 500), count: 10)
        )
        do {
            _ = try await BoundedHTTPReader.fetch(
                request: request(), maxBytes: 2_000_000,
                sessionConfiguration: mockConfig(), refuseBinaryMIME: true
            )
            XCTFail("binaire aurait dû être refusé")
        } catch let err as BoundedHTTPReader.ReaderError {
            XCTAssertEqual(err, .binaryRefused(mime: "image/png"))
        } catch {
            XCTFail("mauvais type d'erreur : \(error)")
        }
        // Refus sur les headers : quelques chunks en vol (race d'ordonnancement)
        // peuvent partir avant que le cancel ne se propage, jamais le corps
        // entier — le flux reste ensuite gelé (borné).
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertLessThan(BoundedMockProtocol.sentChunks, BoundedMockProtocol.totalChunks)
    }

    // MIME absent/mensonger + corps non-UTF8 : le plafond s'applique quand même,
    // puis le décodage strict échoue (l'appelant refuse en binaire).
    func testMissingMIMEStillBoundedAndDecodeFails() async throws {
        BoundedMockProtocol.stub = .init(
            status: 200,
            headers: [:], // aucun Content-Type, aucun Content-Length
            chunks: [Data((0..<200).map { _ in UInt8.random(in: 0x80...0xFF) })]
        )
        let res = try await BoundedHTTPReader.fetch(
            request: request(), maxBytes: 100, sessionConfiguration: mockConfig(),
            refuseBinaryMIME: true // ne doit pas refuser sans MIME : c'est le décodage qui tranche
        )
        XCTAssertEqual(res.data.count, 100)
        XCTAssertNil(BoundedHTTPReader.decodeText(data: res.data, truncated: false))
    }

    // Statut HTTP en erreur : pas de corps chargé.
    func testHTTPErrorStatusLoadsNoBody() async throws {
        BoundedMockProtocol.stub = .init(
            status: 500,
            headers: ["Content-Type": "text/html"],
            chunks: Array(repeating: Data(repeating: 0x41, count: 500), count: 10)
        )
        do {
            _ = try await BoundedHTTPReader.fetch(
                request: request(), maxBytes: 200, sessionConfiguration: mockConfig()
            )
            XCTFail("statut 500 aurait dû throw")
        } catch let err as BoundedHTTPReader.ReaderError {
            XCTAssertEqual(err, .httpStatus(500))
        } catch {
            XCTFail("mauvais type d'erreur : \(error)")
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertLessThan(BoundedMockProtocol.sentChunks, BoundedMockProtocol.totalChunks)
    }

    // Coupure au milieu d'un caractère UTF-8 : décodage réparé, jamais nil.
    func testUTF8CutMidCharacterDecodesCleanly() async throws {
        // 98 x "a" + "€" (3 octets E2 82 AC) = 101 octets ; plafond 100 = coupe
        // au milieu du "€" (2/3 octets conservés).
        var full = Data(repeating: 0x61, count: 98)
        full.append(contentsOf: "€".utf8) // E2 82 AC
        XCTAssertEqual(full.count, 101)
        BoundedMockProtocol.stub = .init(
            status: 200,
            headers: ["Content-Type": "text/html"],
            chunks: [full]
        )
        let res = try await BoundedHTTPReader.fetch(
            request: request(), maxBytes: 100, sessionConfiguration: mockConfig()
        )
        XCTAssertEqual(res.data.count, 100) // brut capé, avec queue partielle
        XCTAssertTrue(res.truncated)
        let text = BoundedHTTPReader.decodeText(data: res.data, truncated: res.truncated)
        XCTAssertNotNil(text) // réparé (rogne jusqu'à 3 octets), jamais de nil silencieux
        XCTAssertEqual(text, String(repeating: "a", count: 98))
    }

    // Pur : non-tronqué invalide = nil (binaire), tronqué = réparé.
    func testDecodeTextPureSemantics() {
        let partialEuro = Data([0xE2, 0x82]) // "€" coupé
        XCTAssertNil(BoundedHTTPReader.decodeText(data: partialEuro, truncated: false))
        XCTAssertNotNil(BoundedHTTPReader.decodeText(data: partialEuro, truncated: true))
    }

    // Pur : classification MIME binaire.
    func testBinaryMIMEClassification() {
        XCTAssertFalse(BoundedHTTPReader.isBinaryMIME(nil))
        XCTAssertFalse(BoundedHTTPReader.isBinaryMIME(""))
        XCTAssertFalse(BoundedHTTPReader.isBinaryMIME("text/html"))
        XCTAssertFalse(BoundedHTTPReader.isBinaryMIME("text/plain; charset=utf-8"))
        XCTAssertFalse(BoundedHTTPReader.isBinaryMIME("application/json"))
        XCTAssertFalse(BoundedHTTPReader.isBinaryMIME("application/ld+json"))
        XCTAssertTrue(BoundedHTTPReader.isBinaryMIME("image/png"))
        XCTAssertTrue(BoundedHTTPReader.isBinaryMIME("video/mp4"))
        XCTAssertTrue(BoundedHTTPReader.isBinaryMIME("application/octet-stream"))
        XCTAssertTrue(BoundedHTTPReader.isBinaryMIME("application/pdf"))
    }

    // Limites verrouillées : pages 2 Mo (historique), JSON 512 Ko (justifié).
    func testLimitsAreLocked() {
        XCTAssertEqual(BoundedHTTPReader.maxPageBytes, 2_000_000)
        XCTAssertEqual(BoundedHTTPReader.maxJSONBytes, 512_000)
        XCTAssertEqual(WebTools.maxPageBytes, 2_000_000)
        XCTAssertEqual(WebSearchService.maxPageBytes, 2_000_000)
    }

    // Sous le plafond : passage intégral, pas de troncation, tout envoyé.
    func testUnderLimitPassesThrough() async throws {
        BoundedMockProtocol.stub = .init(
            status: 200,
            headers: ["Content-Type": "text/html", "Content-Length": "80"],
            chunks: [Data(repeating: 0x41, count: 40), Data(repeating: 0x42, count: 40)]
        )
        let res = try await BoundedHTTPReader.fetch(
            request: request(), maxBytes: 200, sessionConfiguration: mockConfig()
        )
        XCTAssertEqual(res.data.count, 80)
        XCTAssertFalse(res.truncated)
        XCTAssertFalse(res.contentLengthMismatch)
        XCTAssertEqual(BoundedMockProtocol.sentChunks, BoundedMockProtocol.totalChunks)
    }

    // Course annulation/plafond, côté « annulation observée avant validation » :
    // le serveur envoie la réponse puis se tait (le fetch ne peut se terminer
    // que par annulation — aucun timing n'influence l'issue, le test est
    // déterministe). Le fetch termine en CancellationError et stopLoading part.
    func testCallerCancelBeforeValidationWins() async throws {
        BoundedMockProtocol.stub = .init(
            status: 200,
            headers: ["Content-Type": "text/html"],
            chunks: [],
            hangAfterResponse: true
        )
        let fetchTask = Task {
            try await BoundedHTTPReader.fetch(
                request: request(), maxBytes: 200, sessionConfiguration: mockConfig()
            )
        }
        // Annulation immédiate : qu'elle arrive avant ou après la création de
        // la dataTask, `cancelFromCaller` + `run()` la rendent effective et le
        // seul dénouement possible est l'annulation (le serveur ne finira jamais).
        fetchTask.cancel()
        do {
            _ = try await fetchTask.value
            XCTFail("fetch annulé avant validation aurait dû terminer en CancellationError")
        } catch is CancellationError {
            // Attendu : l'annulation observée avant validation l'emporte.
        } catch {
            XCTFail("CancellationError attendue, reçu : \(error)")
        }
        // Requête réellement interrompue : stopLoading vérifié explicitement.
        var stopped = false
        for _ in 0..<100 {
            if BoundedMockProtocol.stopLoadingCount >= 1 { stopped = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(stopped, "stopLoading aurait dû être appelé après l'annulation")
        XCTAssertEqual(BoundedMockProtocol.sentChunks, 0)
    }

    // Course annulation/plafond, côté « résultat déjà validé » : le fetch se
    // termine en succès AVANT l'annulation, qui ne remplace plus le résultat.
    // L'ordre est forcé par construction (valeur reçue puis cancel), donc
    // déterministe lui aussi.
    func testCancelAfterValidationDoesNotReplaceResult() async throws {
        BoundedMockProtocol.stub = .init(
            status: 200,
            headers: ["Content-Type": "text/html", "Content-Length": "80"],
            chunks: [Data(repeating: 0x41, count: 80)]
        )
        let fetchTask = Task {
            try await BoundedHTTPReader.fetch(
                request: request(), maxBytes: 200, sessionConfiguration: mockConfig()
            )
        }
        let res = try await fetchTask.value // succès validé ici…
        fetchTask.cancel() // …cette annulation ultérieure est sans effet.
        XCTAssertEqual(res.data.count, 80)
        XCTAssertFalse(res.truncated)
        XCTAssertFalse(res.contentLengthMismatch)
    }

    // Annulation de la tâche appelante pendant un transfert : stopLoading est
    // déclenché et le fetch termine en annulation, jamais en succès.
    func testCallerCancellationStopsTransfer() async throws {
        let chunk = Data(repeating: 0x43, count: 100)
        BoundedMockProtocol.stub = .init(
            status: 200,
            headers: ["Content-Type": "text/html"],
            chunks: Array(repeating: chunk, count: 50) // ~250 ms de transfert
        )
        let fetchTask = Task {
            try await BoundedHTTPReader.fetch(
                request: request(), maxBytes: 100_000, sessionConfiguration: mockConfig()
            )
        }
        // Attendre un transfert réellement en vol avant d'annuler.
        var inFlight = false
        for _ in 0..<200 {
            if BoundedMockProtocol.sentChunks >= 2 { inFlight = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(inFlight, "le transfert aurait dû démarrer avant l'annulation")
        fetchTask.cancel()
        do {
            _ = try await fetchTask.value
            XCTFail("fetch annulé aurait dû terminer en CancellationError, pas en succès")
        } catch is CancellationError {
            // Attendu : annulation appelante ≠ succès (même partiel).
        } catch {
            XCTFail("CancellationError attendue, reçu : \(error)")
        }
        // stopLoading explicitement vérifié (livraison async → attente bornée).
        var stopped = false
        for _ in 0..<100 {
            if BoundedMockProtocol.stopLoadingCount >= 1 { stopped = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(stopped, "stopLoading aurait dû être appelé après l'annulation")
        // Et le flux reste gelé : rien de plus ne circule après l'annulation.
        let sentAtCancel = BoundedMockProtocol.sentChunks
        XCTAssertLessThan(sentAtCancel, BoundedMockProtocol.totalChunks)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(BoundedMockProtocol.sentChunks, sentAtCancel)
    }

    // Content-Length supérieur au plafond, puis erreur réseau AVANT le plafond :
    // l'erreur remonte, aucun succès partiel inventé.
    func testAnnouncedLengthThenNetworkErrorIsError() async throws {
        let chunk = Data(repeating: 0x44, count: 50)
        BoundedMockProtocol.stub = .init(
            status: 200,
            headers: ["Content-Type": "text/html", "Content-Length": "1000000"],
            chunks: Array(repeating: chunk, count: 10),
            failAtChunk: 2 // 100 octets reçus < plafond 200, puis coupure réseau
        )
        do {
            _ = try await BoundedHTTPReader.fetch(
                request: request(), maxBytes: 200, sessionConfiguration: mockConfig()
            )
            XCTFail("l'erreur réseau aurait dû remonter, pas un succès partiel")
        } catch let err as BoundedHTTPReader.ReaderError {
            guard case .network = err else {
                XCTFail("ReaderError.network attendue, reçu : \(err)")
                return
            }
        } catch {
            XCTFail("ReaderError.network attendue, reçu : \(error)")
        }
    }

    // Corps terminé sous le plafond malgré un Content-Length incohérent :
    // pas de troncation inventée, incohérence explicitement signalée.
    func testInconsistentContentLengthCompletedUnderCap() async throws {
        BoundedMockProtocol.stub = .init(
            status: 200,
            headers: ["Content-Type": "text/html", "Content-Length": "1000000"],
            chunks: [Data(repeating: 0x45, count: 100)] // corps complet : 100 < 200
        )
        let res = try await BoundedHTTPReader.fetch(
            request: request(), maxBytes: 200, sessionConfiguration: mockConfig()
        )
        XCTAssertEqual(res.data.count, 100)
        XCTAssertFalse(res.truncated, "aucune coupe réelle → pas de troncation")
        XCTAssertTrue(res.contentLengthMismatch, "incohérence d'en-tête explicitement signalée")
    }

    // Note de troncation explicite (exigée dans le résultat texte).
    func testTruncationNoteMentionsLimit() {
        let note = BoundedHTTPReader.truncationNote(limit: 2_000_000)
        XCTAssertTrue(note.contains("tronqué"))
        XCTAssertTrue(note.contains("2_000_000") || note.contains("2000000"))
    }
}

// MARK: - Session simulée : envoie les chunks en différé pour que le cancel
// du lecteur interrompe réellement la suite (stopLoading).

private final class BoundedMockProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let status: Int
        let headers: [String: String]
        let chunks: [Data]
        /// Index de chunk où le transfert échoue (nil = succès complet).
        var failAtChunk: Int?
        var failure: Error = URLError(.networkConnectionLost)
        /// Réponse envoyée puis silence (ni corps ni fin) : le fetch reste en
        /// vol et ne peut se terminer que par annulation — course déterministe.
        var hangAfterResponse: Bool = false
    }

    private static let lock = NSLock()
    private static var _stub: Stub?
    private static var _sentChunks = 0
    private static var _totalChunks = 0
    private static var _stopCount = 0

    static var stub: Stub? {
        get { lock.withLock { _stub } }
        set { lock.withLock { _stub = newValue } }
    }
    static var sentChunks: Int { lock.withLock { _sentChunks } }
    static var totalChunks: Int { lock.withLock { _totalChunks } }
    static var stopLoadingCount: Int { lock.withLock { _stopCount } }

    static func reset() {
        lock.withLock {
            _stub = nil
            _sentChunks = 0
            _totalChunks = 0
            _stopCount = 0
        }
    }

    // État `cancelled` synchronisé : `stopLoading` (fil session) et `sendNext`
    // (file global) se disputent cet état sans ordre garanti.
    private let instanceLock = NSLock()
    private var _cancelled = false
    private var isCancelled: Bool { instanceLock.withLock { _cancelled } }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.stub, let url = request.url,
              let resp = HTTPURLResponse(url: url, statusCode: stub.status,
                                         httpVersion: "HTTP/1.1", headerFields: stub.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Self.lock.withLock { Self._totalChunks = stub.chunks.count }
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if stub.hangAfterResponse { return }
        // Si la réponse seule suffit à décider (statut/binaire), le delegate a
        // déjà annulé : ne pas envoyer de corps.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { [weak self] in
            self?.sendNext(index: 0)
        }
    }

    private func sendNext(index: Int) {
        guard let stub = Self.stub else { return }
        if isCancelled { return }
        if let failAt = stub.failAtChunk, index == failAt {
            client?.urlProtocol(self, didFailWithError: stub.failure)
            return
        }
        guard index < stub.chunks.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didLoad: stub.chunks[index])
        Self.lock.withLock { Self._sentChunks += 1 }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { [weak self] in
            self?.sendNext(index: index + 1)
        }
    }

    override func stopLoading() {
        instanceLock.withLock { _cancelled = true }
        Self.lock.withLock { Self._stopCount += 1 }
    }
}
