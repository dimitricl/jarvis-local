@testable import JarvisLocal
import Darwin // inet_pton pour construire les in_addr de test
import Foundation // URL
import Testing

/// Garde-fous sécurité issus de l'audit : écrits en Swift Testing (`@Test`,
/// toolchain Swift 6 — voir le verdict de l'audit : nouveau code en Testing,
/// les 251 XCTest existants ne sont pas migrés).
struct SecurityGuardsTests {
    // MARK: - Confirmation : effet résolu, pas nom brut

    @Test @MainActor func confirmationKeyKeepsSensitiveNative() {
        let sensitive = AppViewModel().sensitiveTools
        #expect(AppViewModel.confirmationKey(for: "send_message", sensitive: sensitive) == "send_message")
        #expect(AppViewModel.confirmationKey(for: "search_web", sensitive: sensitive) == nil)
        #expect(AppViewModel.confirmationKey(for: "unknown_tool_xyz", sensitive: sensitive) == nil)
    }

    @Test @MainActor func confirmationKeyMapsMCPToNative() {
        // Sans ce mapping, events_create via iMCP s'exécutait sans confirmation.
        let sensitive = AppViewModel().sensitiveTools
        #expect(AppViewModel.confirmationKey(for: "events_create", sensitive: sensitive) == "add_calendar_event")
        #expect(AppViewModel.confirmationKey(for: "reminders_create", sensitive: sensitive) == "add_reminder")
        #expect(AppViewModel.confirmationKey(for: "events_fetch", sensitive: sensitive) == nil) // lecture seule
        #expect(AppViewModel.confirmationKey(for: "contacts_search", sensitive: sensitive) == nil) // lecture seule
    }

    // MARK: - URLSafety

    private func v4(_ string: String) -> in_addr {
        var addr = in_addr()
        precondition(inet_pton(AF_INET, string, &addr) == 1, "IP de test invalide : \(string)")
        return addr
    }

    @Test func privateIPv4RangesBlocked() {
        for ip in ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1",
                   "127.0.0.1", "169.254.10.20", "0.0.0.0", "224.0.0.1", "100.64.0.1"] {
            #expect(URLSafety.isPrivateV4(v4(ip)), "\(ip) devrait être privée")
        }
    }

    @Test func publicIPv4Allowed() {
        for ip in ["93.184.216.34", "8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1"] {
            #expect(!URLSafety.isPrivateV4(v4(ip)), "\(ip) devrait être publique")
        }
    }

    @Test func blockedURLsRefused() {
        for raw in ["file:///etc/passwd", "http://localhost:11434/api/tags",
                    "http://127.0.0.1/", "http://169.254.169.254/", "ftp://example.com/x"] {
            #expect(URLSafety.isBlocked(URL(string: raw)!), "\(raw) devrait être refusée")
        }
    }

    @Test func publicLiteralIPAllowedWithoutDNS() {
        // Littéral public : aucun DNS requis, déterministe hors-ligne.
        #expect(!URLSafety.isBlocked(URL(string: "http://93.184.216.34/")!))
    }

    // MARK: - Allowlist typée (PowerAction, handle message)

    @Test func powerActionParsing() {
        #expect(SystemTools.PowerAction(userInput: "sleep") == .sleep)
        #expect(SystemTools.PowerAction(userInput: "veille") == .sleep)
        #expect(SystemTools.PowerAction(userInput: "LOCK") == .lock)
        #expect(SystemTools.PowerAction(userInput: "éteindre") == .shutdown)
        #expect(SystemTools.PowerAction(userInput: "redémarrer") == .restart)
        #expect(SystemTools.PowerAction(userInput: "rm -rf ~") == nil)
        #expect(SystemTools.PowerAction(userInput: "") == nil)
    }

    @Test func messageHandleAllowlist() {
        #expect(MessagingTools.isValidHandle("+33612345678"))
        #expect(MessagingTools.isValidHandle("+32 470 12 34 56"))
        #expect(MessagingTools.isValidHandle("prenom.nom@example.com"))
        #expect(!MessagingTools.isValidHandle(""))
        #expect(!MessagingTools.isValidHandle("+33\"; do shell script \"x"))
        #expect(!MessagingTools.isValidHandle("0123"))
        #expect(!MessagingTools.isValidHandle("not an email"))
    }

    @Test func httpURLAllowlist() {
        #expect(SystemTools.httpURL(from: "https://example.com") != nil)
        #expect(SystemTools.httpURL(from: "example.com") != nil)
        #expect(SystemTools.httpURL(from: "file:///etc/passwd") == nil)
        #expect(SystemTools.httpURL(from: "ftp://example.com") == nil)
    }
}
