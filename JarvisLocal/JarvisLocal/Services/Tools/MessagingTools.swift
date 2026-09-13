import Foundation
import Contacts
import AppKit

/// Domaine Messagerie (Contacts + Messages via AppleScript).
/// Code déplacé à l'identique depuis ToolService.
/// Pourquoi isolé : la résolution du contact (permission Contacts) et l'envoi
/// (AppleScript Messages, main-thread) sont deux échecs distincts — l'isolement
/// rend chaque message d'erreur testable ("introuvable" vs "envoi impossible").
actor MessagingTools {
    func send(contact: String, message: String) async throws -> String {
        let handle = try await lookupContactHandle(contact)
        guard !handle.isEmpty else {
            return "Contact \"\(contact)\" introuvable dans l'app Contacts."
        }

        let escapedMessage = message.escapingForAppleScript
        let escapedHandle = handle.escapingForAppleScript

        let script = """
        tell application "Messages"
            -- essayer iMessage d'abord
            try
                set targetService to 1st service whose service type = iMessage
                send "\(escapedMessage)" to buddy "\(escapedHandle)" of targetService
                return "Message envoyé par iMessage."
            on error
                -- fallback SMS
                try
                    set targetService to 1st service whose service type = SMS
                    send "\(escapedMessage)" to buddy "\(escapedHandle)" of targetService
                    return "Message envoyé par SMS (iMessage indisponible)."
                on error
                    return "Impossible d'envoyer le message. Vérifie que le contact a un numéro valide."
                end try
            end try
        end tell
        """
        return try await AppleScriptRunner.run(script)
    }

    /// Résout "Prénom Nom" → numéro international ou email.
    /// `internal` pour les tests (numéros +33 / +32 / emails).
    func lookupContactHandle(_ name: String) async throws -> String {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            let authorized = try await store.requestAccess(for: .contacts)
            guard authorized else { return "" }
        } else if status != .authorized {
            return ""
        }

        let keys: [CNKeyDescriptor] = [
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)

        guard let contact = contacts.first else { return "" }

        if let phone = contact.phoneNumbers.first?.value.stringValue {
            // Le "+" doit être testé sur la chaîne ORIGINALE : le composant digits
            // ci-dessous retire déjà tous les caractères non-numériques, donc tester
            // hasPrefix("+") sur digits était toujours false et les numéros
            // internationaux (+32, +41…) perdaient leur indicatif au profit d'un
            // "+33" erroné.
            if phone.hasPrefix("+") { return phone }
            var digits = phone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            digits = String(digits.drop(while: { $0 == "0" }))
            return "+33\(digits)"
        }
        if let email = contact.emailAddresses.first?.value as String? {
            return email
        }
        return ""
    }

    /// Normalisation pure d'un numéro brut (sans accès Contacts).
    /// `internal`/`static` pour les tests : la logique "+33" est le bug
    /// historique de ce domaine, elle doit rester couverte sans permission.
    nonisolated static func normalizePhone(_ phone: String) -> String {
        if phone.hasPrefix("+") { return phone }
        var digits = phone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        digits = String(digits.drop(while: { $0 == "0" }))
        return "+33\(digits)"
    }
}
