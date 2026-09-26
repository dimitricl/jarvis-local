import JarvisCore
import XCTest

/// Socle Health Check : classification pure, sans réseau ni Ollama.
final class HealthCheckTests: XCTestCase {
    func testSupportedLocalNoMCPHasNoIssues() {
        let got = HealthCheck.issues(
            toolSupport: .supported, mcpEnabled: false, mcpOnline: nil, ollamaHostIsLocal: true
        )
        XCTAssertTrue(got.isEmpty, "tout vert → aucun bandeau, obtenu : \(got)")
    }

    func testUnsupportedModelReportsNoTools() {
        let got = HealthCheck.issues(
            toolSupport: .unsupported("Le modèle n'a émis aucun tool_call."),
            mcpEnabled: false, mcpOnline: nil, ollamaHostIsLocal: true
        )
        XCTAssertEqual(got.map(\.kind), [.modelNoTools])
        XCTAssertTrue(got[0].message.contains("tool_call"))
    }

    func testUnreachableProbeReportsOllamaDown() {
        let got = HealthCheck.issues(
            toolSupport: .unknown("Ollama injoignable : connexion refusée"),
            mcpEnabled: false, mcpOnline: nil, ollamaHostIsLocal: true
        )
        XCTAssertEqual(got.map(\.kind), [.ollamaUnreachable])
    }

    func testNonNetworkUnknownReportsNothing() {
        // Sonde indéterminée non-réseau (ex. défaut provider) : aucun bandeau,
        // on n'accuse ni le serveur ni le modèle.
        let got = HealthCheck.issues(
            toolSupport: .unknown("Sonde non supportée par ce provider."),
            mcpEnabled: false, mcpOnline: nil, ollamaHostIsLocal: true
        )
        XCTAssertTrue(got.isEmpty, "indéterminé non-réseau → silence, obtenu : \(got)")
    }

    func testRemoteHostWarnsPrivacy() {
        let got = HealthCheck.issues(
            toolSupport: .supported, mcpEnabled: false, mcpOnline: nil, ollamaHostIsLocal: false
        )
        XCTAssertEqual(got.map(\.kind), [.ollamaRemote])
    }

    func testMCPEnabledButOfflineWarns() {
        let got = HealthCheck.issues(
            toolSupport: .supported, mcpEnabled: true, mcpOnline: false, ollamaHostIsLocal: true
        )
        XCTAssertEqual(got.map(\.kind), [.mcpOffline])
    }

    func testMCPOnlineOrUnconfiguredIsSilent() {
        for online: Bool? in [true, nil] {
            let got = HealthCheck.issues(
                toolSupport: .supported, mcpEnabled: online == nil ? false : true,
                mcpOnline: online, ollamaHostIsLocal: true
            )
            XCTAssertTrue(got.isEmpty, "mcpOnline=\(String(describing: online)) → silence, obtenu : \(got)")
        }
    }

    func testIssuesCombine() {
        let got = HealthCheck.issues(
            toolSupport: .unsupported("pas de tool_call"),
            mcpEnabled: true, mcpOnline: false, ollamaHostIsLocal: false
        )
        XCTAssertEqual(got.map(\.kind), [.modelNoTools, .ollamaRemote, .mcpOffline])
    }

    func testIssuesHaveStableIDs() {
        let got = HealthCheck.issues(
            toolSupport: .unsupported("x"), mcpEnabled: false, mcpOnline: nil, ollamaHostIsLocal: false
        )
        XCTAssertEqual(got.map(\.id), got.map { $0.kind.rawValue })
    }
}
