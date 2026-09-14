import Foundation
import EventKit

/// Domaine Rappels (EventKit). Code déplacé à l'identique depuis ToolService.
/// Pourquoi un actor : partage le store unique du contexte, sérialise les
/// `fetchReminders` à continuation qui sinon se chevauchent.
actor RemindersTools {
    private let ctx: ToolContext
    init(ctx: ToolContext) { self.ctx = ctx }

    func add(title: String, notes: String?, dueDate: String?, dueTime: String?) async throws -> String {
        let status = try await ctx.eventStore.requestFullAccessToReminders()
        guard status else { return "Accès aux rappels refusé." }

        let reminder = EKReminder(eventStore: ctx.eventStore)
        reminder.title = title
        if let n = notes { reminder.notes = n }
        reminder.calendar = ctx.eventStore.defaultCalendarForNewReminders()

        if let dd = dueDate {
            let parts = dd.split(separator: "/").map { Int($0) }
            guard parts.count == 3, let d = parts[0], let m = parts[1], let y = parts[2] else {
                return "Date invalide."
            }
            let comps = dueTime?.split(separator: ":").compactMap { Int($0) } ?? [23, 59]
            var dateComps = DateComponents()
            dateComps.year = y; dateComps.month = m; dateComps.day = d
            dateComps.hour = comps.first; dateComps.minute = comps.count > 1 ? comps[1] : 59
            reminder.dueDateComponents = dateComps
        }

        try ctx.eventStore.save(reminder, commit: true)
        return "Rappel \"\(title)\" créé\(notes != nil ? " avec notes" : "")\(dueDate != nil ? " pour le \(dueDate!)" : "")."
    }

    func list(list: String?) async throws -> String {
        let status = try await ctx.eventStore.requestFullAccessToReminders()
        guard status else { return "Accès aux rappels refusé." }

        let predicate: NSPredicate
        if let listName = list {
            let calendars = ctx.eventStore.calendars(for: .reminder)
            guard let cal = calendars.first(where: { $0.title.localizedCaseInsensitiveContains(listName) }) else {
                return "Liste \"\(listName)\" introuvable."
            }
            predicate = ctx.eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [cal])
        } else {
            let calendars = ctx.eventStore.calendars(for: .reminder)
            predicate = ctx.eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        }

        let reminders = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[EKReminder], Error>) in
            _ = ctx.eventStore.fetchReminders(matching: predicate) { items in
                cont.resume(returning: items ?? [])
            }
        }

        if reminders.isEmpty { return "Aucun rappel en attente." }

        let df = DateFormatter()
        df.dateFormat = "dd/MM/yyyy"

        return reminders.prefix(20).map { reminder in
            let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }.map { df.string(from: $0) } ?? ""
            return "\(reminder.title ?? "")\(due.isEmpty ? "" : " (pour le \(due))")"
        }.joined(separator: "\n")
    }
}
