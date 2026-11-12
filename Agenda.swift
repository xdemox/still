import Combine

import EventKit
import Foundation

@MainActor
final class Agenda: ObservableObject {
    struct Event: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
    }

    @Published private(set) var connected = false
    @Published private(set) var events: [Event] = []
    @Published private(set) var requesting = false
    @Published private(set) var issue: String?
    private lazy var store = EKEventStore()

    func connect() async {
        guard !requesting else { return }
        requesting = true
        defer { requesting = false }
        do {
            if try await store.requestFullAccessToEvents() { refresh() }
            else { issue = "Allow Still in System Settings → Privacy & Security → Calendars." }
        } catch {
            issue = "Still could not read Calendar. \(error.localizedDescription)"
        }
    }

    func refresh() {
        connected = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard connected else { events = []; return }
        issue = nil
        let now = Date.now
        guard let end = Calendar.current.date(byAdding: .day, value: 7, to: now) else { return }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                Event(id: "\(event.eventIdentifier ?? "event")-\(event.startDate.timeIntervalSinceReferenceDate)",
                    title: event.title ?? "Untitled event", start: event.startDate, end: event.endDate)
            }
    }
}
