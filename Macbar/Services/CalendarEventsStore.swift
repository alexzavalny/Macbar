import AppKit
import EventKit

struct MeetingEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let joinURL: URL?

    func isOngoing(at now: Date) -> Bool { start <= now && now < end }
    /// Worth a prominent Join button: running, or starting within ten minutes.
    func isSoon(at now: Date) -> Bool { end > now && start.timeIntervalSince(now) <= 600 }
}

enum MeetingLink {
    private static let hosts = ["zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                "webex.com", "whereby.com", "gotomeeting.com", "around.co", "chime.aws"]

    /// The first video-call link in the given texts (location, notes, URL field), in that order.
    static func find(in texts: [String?]) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector?.matches(in: text, range: range) ?? [] {
                guard let url = match.url, let host = url.host?.lowercased() else { continue }
                if url.scheme == "zoommtg" || hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }
}

@MainActor
final class CalendarEventsStore: ObservableObject {
    enum Access { case granted, notDetermined, denied }

    @Published private(set) var events: [MeetingEvent] = []
    @Published private(set) var access: Access = .notDetermined
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
        refreshAccess()
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    private func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .notDetermined
        default: access = .denied
        }
    }

    /// Meetings that haven't ended, through the end of tomorrow.
    func load() {
        refreshAccess()
        guard access == .granted else { events = []; return }
        let calendar = Calendar.current
        let now = Date()
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return }
        events = store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
            .filter { event in
                !event.isAllDay && event.status != .canceled && event.endDate > now &&
                    event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
            .map { event in
                MeetingEvent(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Untitled",
                             start: event.startDate, end: event.endDate,
                             joinURL: MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes]))
            }
    }

    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
        load()
    }
}
