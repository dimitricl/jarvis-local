import Foundation
import JarvisCore
import EventKit

/// Domaine Calendrier (EventKit). Code déplacé à l'identique depuis
/// ToolService — même parsing DD/MM/YYYY, même choix du calendrier.
/// Pourquoi un actor : `EKEventStore` n'est pas Sendable ; l'actor sérialise
/// les accès et partage le store unique du ToolContext.
actor CalendarTools {
    private let ctx: ToolContext
    init(ctx: ToolContext) { self.ctx = ctx }

    func addEvent(args: [String: Any]) async throws -> String {
        // Extraction stricte AVANT toute demande TCC : un appel sans permission
        // (tests headless) reçoit le message explicite sans faire popper le système.
        // Même contrat que le dispatcher — pas de "" silencieux.
        guard let title = args["title"] as? String else {
            return "Paramètre 'title' manquant ou de type invalide pour l'outil 'add_calendar_event'"
        }
        guard let dateStr = args["date"] as? String else {
            return "Paramètre 'date' manquant ou de type invalide pour l'outil 'add_calendar_event'"
        }
        let startTime: String
        if let raw = args["start_time"] {
            guard let s = raw as? String else {
                return "Paramètre 'start_time' manquant ou de type invalide pour l'outil 'add_calendar_event'"
            }
            startTime = s
        } else { startTime = "09:00" }
        let duration: Int
        if let raw = args["duration_minutes"] {
            switch raw {
            case let d as Int: duration = d
            case let d as Double: duration = Int(d)
            case let n as NSNumber: duration = n.intValue
            default: return "Paramètre 'duration_minutes' manquant ou de type invalide pour l'outil 'add_calendar_event'"
            }
        } else { duration = 60 }
        for k in ["notes", "calendar", "location"] {
            if args[k] != nil, args[k] as? String == nil {
                return "Paramètre '\(k)' manquant ou de type invalide pour l'outil 'add_calendar_event'"
            }
        }
        let notes = args["notes"] as? String
        let calName = args["calendar"] as? String
        let location = args["location"] as? String

        let status = try await ctx.eventStore.requestFullAccessToEvents()
        guard status else { return "Accès au calendrier refusé." }

        let dateParts = dateStr.split(separator: "/").compactMap { Int($0) }
        guard dateParts.count >= 3 else { return "Date invalide." }
        let timeParts = startTime.split(separator: ":").compactMap { Int($0) }

        var comps = DateComponents()
        comps.year = dateParts[2]; comps.month = dateParts[1]; comps.day = dateParts[0]
        comps.hour = timeParts.first ?? 9; comps.minute = timeParts.count > 1 ? timeParts[1] : 0
        guard let startDate = Calendar.current.date(from: comps) else { return "Date invalide." }
        let endDate = startDate.addingTimeInterval(TimeInterval(duration * 60))

        let calendars = ctx.eventStore.calendars(for: .event)
        let calendar: EKCalendar
        if let name = calName {
            let matches = calendars.filter { $0.title.localizedCaseInsensitiveContains(name) }
            guard let match = matches.first else { return "Calendrier \"\(name)\" introuvable." }
            calendar = match
        } else {
            guard let first = calendars.first(where: { $0.allowsContentModifications }) ?? calendars.first else {
                return "Aucun calendrier disponible."
            }
            calendar = first
        }

        let event = EKEvent(eventStore: ctx.eventStore)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = notes
        event.location = location
        event.calendar = calendar

        try ctx.eventStore.save(event, span: .thisEvent)
        return "Événement \"\(title)\" créé le \(dateStr) à \(startTime) (\(duration)min)."
    }

    func getCalendars() async throws -> String {
        let status = try await ctx.eventStore.requestFullAccessToEvents()
        guard status else { return "Accès refusé." }
        let calendars = ctx.eventStore.calendars(for: .event)
        return calendars.map { "\($0.title) (\($0.allowsContentModifications ? "écriture" : "lecture seule"))" }.joined(separator: "\n")
    }

    func upcoming(days: Int) async throws -> String {
        let status = try await ctx.eventStore.requestFullAccessToEvents()
        guard status else { return "Accès au calendrier refusé." }

        let startDate = Date()
        guard let endDate = Calendar.current.date(byAdding: .day, value: days, to: startDate) else {
            return "Erreur de date."
        }

        let calendars = ctx.eventStore.calendars(for: .event)
        let predicate = ctx.eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = ctx.eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        if events.isEmpty { return "Aucun événement dans les \(days) prochains jours." }

        let df = DateFormatter()
        df.dateFormat = "dd/MM HH:mm"

        return events.prefix(20).map { event in
            let start = df.string(from: event.startDate)
            let location = event.location ?? ""
            // Identifiant exposé au modèle : edit/delete exigent un id issu de CE
            // listing, jamais un titre approximatif deviné.
            return "\(start) - \(event.title ?? "")\(location.isEmpty ? "" : " @ \(location)") [id: \(event.eventIdentifier ?? "")]"
        }.joined(separator: "\n")
    }

    /// Modifie un événement existant à partir de son identifiant (obtenu via
    /// get_upcoming_events). `changes` = sous-ensemble plat des champs de
    /// add_calendar_event (title, date DD/MM/YYYY, start_time HH:MM,
    /// duration_minutes, notes, location, calendar). Champs absents = inchangés.
    func editEvent(id: String, changes: [String: Any]) async throws -> String {
        let status = try await ctx.eventStore.requestFullAccessToEvents()
        guard status else { return "Accès au calendrier refusé." }

        guard let event = ctx.eventStore.event(withIdentifier: id) else {
            return "Événement introuvable (id: \(id)). Liste d'abord avec get_upcoming_events pour obtenir un identifiant valide."
        }
        guard event.calendar.allowsContentModifications else {
            return "Événement en lecture seule (calendrier \"\(event.calendar.title)\")."
        }

        if let raw = changes["title"] {
            guard let t = raw as? String else {
                return "Paramètre 'title' manquant ou de type invalide pour l'outil 'edit_calendar_event'"
            }
            event.title = t
        }
        // Recomposition start/end seulement si un composant temporel change.
        let newDateStr = changes["date"] as? String
        let newStartTime = changes["start_time"] as? String
        if changes["date"] != nil, newDateStr == nil {
            return "Paramètre 'date' manquant ou de type invalide pour l'outil 'edit_calendar_event'"
        }
        if changes["start_time"] != nil, newStartTime == nil {
            return "Paramètre 'start_time' manquant ou de type invalide pour l'outil 'edit_calendar_event'"
        }
        var newDuration: Int?
        if let raw = changes["duration_minutes"] {
            switch raw {
            case let d as Int: newDuration = d
            case let d as Double: newDuration = Int(d)
            case let n as NSNumber: newDuration = n.intValue
            default: return "Paramètre 'duration_minutes' manquant ou de type invalide pour l'outil 'edit_calendar_event'"
            }
        }
        if newDateStr != nil || newStartTime != nil || newDuration != nil {
            let df = DateFormatter()
            df.dateFormat = "dd/MM/yyyy HH:mm"
            let baseStart = event.startDate ?? Date()
            let cal = Calendar.current
            let dComps = cal.dateComponents([.year, .month, .day], from: baseStart)
            let tComps = cal.dateComponents([.hour, .minute], from: baseStart)
            let dateParts = (newDateStr ?? String(format: "%02d/%02d/%04d", dComps.day ?? 1, dComps.month ?? 1, dComps.year ?? 2000))
                .split(separator: "/").compactMap { Int($0) }
            guard dateParts.count >= 3 else { return "Date invalide." }
            let timeParts = (newStartTime ?? String(format: "%02d:%02d", tComps.hour ?? 9, tComps.minute ?? 0))
                .split(separator: ":").compactMap { Int($0) }
            var comps = DateComponents()
            comps.year = dateParts[2]; comps.month = dateParts[1]; comps.day = dateParts[0]
            comps.hour = timeParts.first ?? 9; comps.minute = timeParts.count > 1 ? timeParts[1] : 0
            guard let startDate = Calendar.current.date(from: comps) else { return "Date invalide." }
            let existingDuration: Int = {
                if let s = event.startDate, let e = event.endDate { return Int(e.timeIntervalSince(s) / 60) }
                return 60
            }()
            let duration = newDuration ?? existingDuration
            event.startDate = startDate
            event.endDate = startDate.addingTimeInterval(TimeInterval(duration * 60))
        }
        if let raw = changes["notes"] {
            guard let n = raw as? String else {
                return "Paramètre 'notes' manquant ou de type invalide pour l'outil 'edit_calendar_event'"
            }
            event.notes = n
        }
        if let raw = changes["location"] {
            guard let l = raw as? String else {
                return "Paramètre 'location' manquant ou de type invalide pour l'outil 'edit_calendar_event'"
            }
            event.location = l
        }
        if let raw = changes["calendar"] {
            guard let name = raw as? String else {
                return "Paramètre 'calendar' manquant ou de type invalide pour l'outil 'edit_calendar_event'"
            }
            let calendars = ctx.eventStore.calendars(for: .event)
            let matches = calendars.filter { $0.title.localizedCaseInsensitiveContains(name) }
            guard let match = matches.first else { return "Calendrier \"\(name)\" introuvable." }
            event.calendar = match
        }

        try ctx.eventStore.save(event, span: .thisEvent)
        return "Événement \"\(event.title ?? "")\" mis à jour."
    }

    /// Supprime un événement à partir de son identifiant (obtenu via get_upcoming_events).
    func deleteEvent(id: String) async throws -> String {
        let status = try await ctx.eventStore.requestFullAccessToEvents()
        guard status else { return "Accès au calendrier refusé." }

        guard let event = ctx.eventStore.event(withIdentifier: id) else {
            return "Événement introuvable (id: \(id)). Liste d'abord avec get_upcoming_events pour obtenir un identifiant valide."
        }
        guard event.calendar.allowsContentModifications else {
            return "Événement en lecture seule (calendrier \"\(event.calendar.title)\")."
        }
        let title = event.title ?? ""
        try ctx.eventStore.remove(event, span: .thisEvent)
        return "Événement \"\(title)\" supprimé."
    }
}
