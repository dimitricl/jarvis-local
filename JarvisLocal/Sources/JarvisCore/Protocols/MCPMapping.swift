import Foundation

/// Correspondance outil natif → outil MCP qui le remplace quand le serveur
/// est en ligne. Déplacée à l'identique depuis MCPToolProvider : c'est le
/// CONTRAT de délégation (le modèle ne doit voir qu'UN outil par action),
/// consommé à la fois par ToolService (masquage, côté Services) et par
/// AppViewModel.confirmationKey (résolution de confirmation, côté UI).
/// Source unique — MCPToolProvider ne fait que la réexporter.
public enum MCPToolMapping {
    /// Noms MCP vérifiés en test réel (serveur v1.4.1) ; `send_message` n'y figure
    /// PAS (iMCP = lecture seule sur Messages) et reste donc toujours natif.
    public static let nativeToMCP: [String: String] = [
        "add_calendar_event": "events_create",
        "get_calendars": "calendars_list",
        "get_upcoming_events": "events_fetch",
        "add_reminder": "reminders_create",
        "list_reminders": "reminders_fetch"
    ]
}
