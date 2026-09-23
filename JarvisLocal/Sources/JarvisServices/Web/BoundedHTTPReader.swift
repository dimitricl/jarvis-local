import Foundation

/// Lecteur HTTP borné partagé (`read_url`, `search_web`, météo).
///
/// Pourquoi un helper dédié : `URLSession.data(for:)` charge TOUTE la réponse
/// en RAM avant de la rendre (Data + copie String + copies regex `htmlToText`).
/// Un `read_url` vers un ISO/vidéo/export montait à 40+ Go. Ici on compte les
/// octets effectivement reçus dans le delegate et on `cancel()` la
/// `URLSessionDataTask` dès que le plafond est atteint — `Content-Length`
/// (`expectedContentLength`) n'est qu'un indice : il ne prouve ni troncation
/// ni intégrité, ne masque jamais une erreur transport et ne marque jamais
/// une réponse comme tronquée à lui seul.
///
/// Bornes :
/// - pages HTML : 2 000 000 octets (limite historique conservée, quelques
///   centaines de Ko pour une page normale, 2 Mo = marge + pic `Data→String`).
/// - JSON (Instant Answer DDG, Open-Meteo) : 512 000 octets. Justification :
///   ces JSON font < 100 Ko en pratique ; 512 Ko = ~5x de marge tout en
///   divisant par 4 le pic mémoire vs la borne pages. Un JSON tronqué est
///   de toute façon inparsable → traité en erreur, pas en texte partiel.
///
/// Garanties :
/// - `task.cancel()` explicite dès `buffer.count >= maxBytes` (la simple
///   sortie du flux n'interrompt pas sûrement la tâche réseau).
/// - Annulation de la tâche Swift appelante propagée à la `URLSessionDataTask`
///   (race-safe, un seul `resume`) : un job annulé termine en
///   `CancellationError`, jamais en succès — distinguée du cancel interne
///   (plafond) par un flag dédié.
/// - `sessionConfiguration` injectable pour les tests (`URLProtocol` simulé,
///   aucun réseau réel).
/// - Décodage UTF-8 sûr sur coupure : `decodeText` rogne jusqu'à 3 octets
///   finaux (taille max d'une séquence UTF-8 coupée) avant fallback lossy,
///   jamais de `nil` silencieux sur texte tronqué.
enum BoundedHTTPReader {
    static let maxPageBytes = 2_000_000
    static let maxJSONBytes = 512_000

    struct Response {
        let data: Data
        let httpResponse: HTTPURLResponse
        /// true UNIQUEMENT si le compteur d'octets a réellement atteint
        /// `maxBytes` et que le lecteur a lui-même annulé la tâche. Jamais
        /// déduit du seul `Content-Length`.
        let truncated: Bool
        /// true si un `Content-Length` connu diffère des octets effectivement
        /// reçus sur une lecture NON tronquée (en-tête incohérent : le serveur
        /// a annoncé plus/moins que ce qu'il a envoyé). Faux quand `truncated`
        /// est vrai (l'écart s'explique alors par notre propre coupe).
        let contentLengthMismatch: Bool
    }

    enum ReaderError: Error, Equatable {
        case httpStatus(Int)
        case invalidResponse
        case binaryRefused(mime: String)
        case network(String)
    }

    /// Fetch borné : compte les octets reçus, annule la tâche au plafond.
    /// - Parameters:
    ///   - request: requête déjà configurée (UA, timeout préservés par l'appelant).
    ///   - maxBytes: plafond strict.
    ///   - sessionConfiguration: nil = `.default` (prod) ; tests = config avec
    ///     `protocolClasses = [Mock]`.
    ///   - refuseBinaryMIME: si true, un `Content-Type` binaire avéré annule
    ///     immédiatement (sans attendre le plafond) en `binaryRefused`.
    ///     Même à true, le plafond streaming reste actif (MIME absent/mensonger).
    /// - Note: une annulation de la tâche Swift appelante annule la
    ///   `URLSessionDataTask` et fait terminer le fetch en `CancellationError`.
    ///   Un `Content-Length` incohérent ne produit jamais `truncated = true` à
    ///   lui seul (voir `Response.contentLengthMismatch`).
    static func fetch(
        request: URLRequest,
        maxBytes: Int,
        sessionConfiguration: URLSessionConfiguration? = nil,
        refuseBinaryMIME: Bool = false
    ) async throws -> Response {
        let delegate = FetchDelegate(maxBytes: maxBytes, refuseBinary: refuseBinaryMIME)
        let config = sessionConfiguration ?? .default
        // Session dédiée par fetch : le delegate est lié à la session à la
        // création ; un singleton partagé ne pourrait pas porter l'état
        // (buffer/compteur) par requête.
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await delegate.run(request: request, session: session)
    }

    // MARK: - Décodage / MIME

    /// MIME binaire avéré (allowlist texte). nil/vide = autorisé (on tente le
    /// décodage UTF-8, le plafond streaming protège de toute façon).
    static func isBinaryMIME(_ mimeType: String?) -> Bool {
        guard let mimeType, !mimeType.isEmpty else { return false }
        let base = mimeType.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } ?? ""
        if base.hasPrefix("text/") { return false }
        switch base {
        case "application/json", "application/xml", "application/xhtml+xml",
             "application/javascript", "application/ecmascript",
             "application/x-javascript":
            return false
        default:
            break
        }
        if base.hasSuffix("+json") || base.hasSuffix("+xml") { return false }
        return true
    }

    /// Décode en String en gérant une coupure milieu de caractère UTF-8.
    /// - Non tronqué : décodage strict, `nil` = binaire/invalide (l'appelant refuse).
    /// - Tronqué : on rogne jusqu'à 3 octets de queue jusqu'à décodage strict,
    ///   sinon fallback lossy (`String(decoding:as:)` → U+FFFD, jamais nil).
    static func decodeText(data: Data, truncated: Bool) -> String? {
        if !truncated {
            return String(data: data, encoding: .utf8)
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        var prefix = data
        for _ in 0..<3 {
            guard !prefix.isEmpty else { break }
            prefix = prefix.dropLast()
            if let s = String(data: prefix, encoding: .utf8) { return s }
        }
        guard !data.isEmpty else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func truncationNote(limit: Int) -> String {
        "\n\n[Contenu tronqué : limite de \(limit) octets atteinte, suite non chargée.]"
    }
}

// MARK: - Delegate borné

private final class FetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let refuseBinary: Bool
    private let lock = NSLock()
    private var buffer = Data()
    private var httpResponse: HTTPURLResponse?
    /// Longueur annoncée (Content-Length) si connue. INDICE seulement : ne
    /// prouve ni troncation ni intégrité, ne masque jamais une erreur.
    private var announcedLength: Int64?
    /// Plafond réellement atteint par le compteur d'octets : seule preuve
    /// d'une coupe (succès partiel). Jamais déduit de l'en-tête.
    private var capReached = false
    /// Annulation demandée par la tâche Swift appelante (via `onCancel`).
    /// Lue uniquement au point de validation synchronisé (`settle`) : observée
    /// avant validation, elle convertit tout succès en `CancellationError` ;
    /// après validation, elle ne remplace plus le résultat.
    private var callerCancelled = false
    private var continuation: CheckedContinuation<BoundedHTTPReader.Response, Error>?
    private var resumed = false
    private weak var task: URLSessionDataTask?

    init(maxBytes: Int, refuseBinary: Bool) {
        self.maxBytes = maxBytes
        self.refuseBinary = refuseBinary
    }

    func run(request: URLRequest, session: URLSession) async throws -> BoundedHTTPReader.Response {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<BoundedHTTPReader.Response, Error>) in
                lock.lock()
                continuation = cont
                lock.unlock()
                let t = session.dataTask(with: request)
                lock.lock()
                task = t
                // Annulation arrivée AVANT l'enregistrement de la tâche :
                // on l'applique maintenant (race-safe). `didComplete`
                // remontera `CancellationError` via `callerCancelled`.
                let cancelledAlready = callerCancelled
                lock.unlock()
                t.resume()
                if cancelledAlready { t.cancel() }
            }
        }, onCancel: {
            cancelFromCaller()
        })
    }

    /// Propagation de l'annulation appelante vers la tâche réseau.
    /// Race-safe : si la tâche n'existe pas encore, `run()` appliquera le
    /// cancel à la création grâce au flag sous lock.
    private func cancelFromCaller() {
        lock.lock()
        callerCancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }

    // Réponse reçue : statut + hint Content-Length + refus binaire précoce.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            settle(.failure(BoundedHTTPReader.ReaderError.invalidResponse))
            return
        }
        lock.lock()
        httpResponse = http
        // Hint uniquement, stocké pour le diagnostic `contentLengthMismatch` :
        // un Content-Length énorme ne pré-marque AUCUNE troncation et ne
        // masquera jamais une erreur (voir `didCompleteWithError`).
        announcedLength = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        let refuse = refuseBinary && BoundedHTTPReader.isBinaryMIME(http.mimeType)
        let mime = http.mimeType ?? "inconnu"
        lock.unlock()
        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            settle(.failure(BoundedHTTPReader.ReaderError.httpStatus(http.statusCode)))
            return
        }
        if refuse {
            completionHandler(.cancel)
            settle(.failure(BoundedHTTPReader.ReaderError.binaryRefused(mime: mime)))
            return
        }
        completionHandler(.allow)
    }

    // Cœur borné : chaque chunk compte, cancel explicite au plafond.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        // Déjà terminé (cancel en cours) : ignorer les chunks tardifs.
        if resumed {
            lock.unlock()
            return
        }
        let room = maxBytes - buffer.count
        if room <= 0 {
            capReached = true
            let t = task
            lock.unlock()
            // Annulation EXPLICITE : sortir du delegate ne garantit pas
            // l'interruption réseau ; cancel() déclenche stopLoading côté
            // protocole et didCompleteWithError(.cancelled) ci-dessous.
            t?.cancel()
            return
        }
        if data.count <= room {
            buffer.append(data)
            if buffer.count >= maxBytes {
                capReached = true
                // Plafond atteint pile : on coupe le flux tout de suite au lieu
                // d'attendre la fin du serveur (qui peut envoyer des Go).
                buffer = buffer.prefix(maxBytes)
                let t = task
                lock.unlock()
                t?.cancel()
                return
            }
            lock.unlock()
            return
        }
        buffer.append(data.prefix(room))
        buffer = buffer.prefix(maxBytes)
        capReached = true
        let t = task
        lock.unlock()
        t?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let capReached = self.capReached
        let http = httpResponse
        let data = buffer
        let announced = announcedLength
        lock.unlock()
        // Erreur transport (timeout, connexion perdue…) ou cancel : jamais
        // masquée par Content-Length (voir `announcedLength`).
        if let error {
            let ns = error as NSError
            let isCancel = ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
            if isCancel && !capReached {
                // Cancel sans plafond atteint = annulation (appelante le plus
                // souvent) : jamais un succès, jamais déguisée en `.network`.
                settle(.failure(CancellationError()))
                return
            }
            if isCancel, capReached, let http {
                // Cancel au plafond : succès partiel, SAUF si l'annulation
                // appelante a été observée avant validation — `settle`
                // tranche cette course atomiquement (voir son contrat).
                settle(.success(BoundedHTTPReader.Response(
                    data: data, httpResponse: http,
                    truncated: true, contentLengthMismatch: false
                )))
                return
            }
            settle(.failure(BoundedHTTPReader.ReaderError.network(error.localizedDescription)))
            return
        }
        // Fin normale du corps : tronqué ssi coupe réelle par le compteur.
        // Un Content-Length supérieur au corps reçu n'invente pas une
        // troncation : l'incohérence est signalée explicitement via
        // `contentLengthMismatch`, sans présenter un corps complet comme
        // tronqué.
        guard let http else {
            settle(.failure(BoundedHTTPReader.ReaderError.invalidResponse))
            return
        }
        let mismatch: Bool = {
            guard !capReached, let announced else { return false }
            return announced != Int64(data.count)
        }()
        settle(.success(BoundedHTTPReader.Response(
            data: data, httpResponse: http,
            truncated: capReached, contentLengthMismatch: mismatch
        )))
    }

    /// Point de validation UNIQUE et synchronisé du résultat du fetch.
    /// Règle de course (annulation appelante vs plafond) : si `callerCancelled`
    /// est observé avant cette validation, un succès proposé devient
    /// `CancellationError` (la requête a été / est annulée via
    /// `cancelFromCaller`). Si la validation a déjà eu lieu (`resumed`), une
    /// annulation ultérieure ne remplace plus le résultat.
    /// Décision + marquage sous le même lock, continuation reprise une fois.
    @discardableResult
    private func settle(_ result: Swift.Result<BoundedHTTPReader.Response, Error>) -> Bool {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return false
        }
        var final = result
        if callerCancelled, case .success = result {
            final = .failure(CancellationError())
        }
        resumed = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        switch final {
        case .success(let r): cont?.resume(returning: r)
        case .failure(let e): cont?.resume(throwing: e)
        }
        return true
    }
}
