import Foundation
import EventKit

/// Domaine Calendrier (EventKit). Code déplacé à l'identique depuis
/// ToolService — même parsing DD/MM/YYYY, même choix du calendrier.
/// Pourquoi un actor : `EKEventStore` n'est pas Sendable ; l'actor sérialise
/// les accès et partage le store unique du ToolContext.
actor CalendarTools {
    private let ctx: ToolContext
    init(ctx: ToolContext) { self.ctx = ctx }

    func addEvent(args: [String: Any]) async throws -> String {
        let status = try await ctx.eventStore.requestFullAccessToEvents()
        guard status else { return "Accès au calendrier refusé." }

        let title = args["title"] as? String ?? ""
        let dateStr = args["date"] as? String ?? ""
        let startTime = args["start_time"] as? String ?? "09:00"
        let duration: Int
        if let d = args["duration_minutes"] as? Int { duration = d }
        else if let d = args["duration_minutes"] as? Double { duration = Int(d) }
        else { duration = 60 }
        let notes = args["notes"] as? String
        let calName = args["calendar"] as? String
        let location = args["location"] as? String

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
            return "\(start) - \(event.title ?? "")\(location.isEmpty ? "" : " @ \(location)")"
        }.joined(separator: "\n")
    }
}
