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

    /// "Now", "in 12 min", or "at 14:00" when it is an hour or more away.
    func countdown(at now: Date) -> String {
        if isOngoing(at: now) { return "Now" }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return minutes < 60 ? "in \(max(minutes, 1)) min" : "at \(start.formatted(date: .omitted, time: .shortened))"
    }
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
    /// The tray widget's meeting: running now or starting within an hour.
    @Published private(set) var next: MeetingEvent?
    private var timer: Timer?
    private var store = EKEventStore()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
        refreshAccess()
    }

    /// Keeps `next` current for the tray widget, without the flyout being open.
    func start() {
        load()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    /// Width the tray widget needs: its label, plus room for Join when the meeting has a call link.
    var trayWidth: CGFloat { next.map { $0.joinURL == nil ? 128 : 172 } ?? 0 }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    private func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .notDetermined
        default: access = .denied
        }
    }

    /// A store opened before access was granted stays blind, so every move into "granted" needs a new one.
    nonisolated static func needsFreshStore(from before: Access, to after: Access) -> Bool { after == .granted && before != .granted }

    /// Meetings that haven't ended, through the end of tomorrow.
    func load() {
        let before = access
        refreshAccess()
        // A store opened before access was granted (here or in the Permissions window) never
        // sees any events, so start a fresh one.
        if Self.needsFreshStore(from: before, to: access) { store = EKEventStore() }
        guard access == .granted else { events = []; next = nil; return }
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
        next = events.first { $0.end > now && $0.start.timeIntervalSince(now) <= 3600 }
    }

    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
        load()
    }
}
