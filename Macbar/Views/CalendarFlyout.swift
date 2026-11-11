import SwiftUI

struct CalendarMonth {
    let date: Date
    let calendar: Calendar

    var firstDay: Date { calendar.date(from: calendar.dateComponents([.year, .month], from: date))! }
    var days: [Date?] {
        let offset = (calendar.component(.weekday, from: firstDay) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: date)!.count
        return Array(repeating: nil, count: offset) + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: firstDay) }
    }
    var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }
}

struct CalendarFlyout: View {
    @ObservedObject var events: CalendarEventsStore
    let join: (URL) -> Void
    @State private var displayedMonth = Date()
    private let calendar = Calendar.current

    var body: some View {
        FlyoutSurface {
            VStack(alignment: .leading, spacing: 18) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day()).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(context.date, format: .dateTime.hour().minute().second()).font(.system(size: 32, weight: .light)).monospacedDigit()
                    }
                }
                Divider().opacity(0.5)
                HStack {
                    Text(displayedMonth, format: .dateTime.month(.wide).year()).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 26, height: 26) }
                        .buttonStyle(TileButtonStyle()).accessibilityLabel("Previous month")
                    Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 26, height: 26) }
                        .buttonStyle(TileButtonStyle()).accessibilityLabel("Next month")
                }
                let month = CalendarMonth(date: displayedMonth, calendar: calendar)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                    ForEach(Array(month.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).frame(height: 20)
                    }
                    ForEach(Array(month.days.enumerated()), id: \.offset) { _, date in
                        if let date {
                            let today = calendar.isDateInToday(date)
                            Text("\(calendar.component(.day, from: date))")
                                .font(.system(size: 12, weight: today ? .semibold : .regular))
                                .foregroundStyle(today ? Color.white : Color.primary)
                                .frame(width: 32, height: 30)
                                .background { if today { Circle().fill(Color.accentColor) } }
                        } else { Color.clear.frame(height: 30) }
                    }
                }
                Divider().opacity(0.5)
                UpcomingMeetings(events: events, join: join)
                Spacer(minLength: 0)
                Button("Back to today") { displayedMonth = Date() }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            .padding(25).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { events.load() }
    }

    private func moveMonth(_ delta: Int) {
        if let date = calendar.date(byAdding: .month, value: delta, to: displayedMonth) { displayedMonth = date }
    }
}

private struct UpcomingMeetings: View {
    @ObservedObject var events: CalendarEventsStore
    let join: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upcoming").font(.system(size: 12, weight: .semibold))
            switch events.access {
            case .granted:
                // Re-read the clock so ended meetings drop off and Join turns prominent.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let upcoming = events.events.filter { $0.end > context.date }
                    if upcoming.isEmpty {
                        Text("No more meetings through tomorrow.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(upcoming.prefix(4)) { MeetingRow(event: $0, now: context.date, join: join) }
                }
            case .notDetermined:
                Text("See your next meetings here and join calls in one click.").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Show my meetings") { Task { await events.requestAccess() } }
                    .buttonStyle(.bordered).font(.system(size: 11))
            case .denied:
                Text("Calendar access is off for Macbar.").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Open Calendar privacy settings ↗") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 11, weight: .medium))
            }
        }
    }
}

private struct MeetingRow: View {
    let event: MeetingEvent
    let now: Date
    let join: (URL) -> Void

    private var when: String {
        let time = "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))"
        if event.isOngoing(at: now) { return "Now · until \(event.end.formatted(date: .omitted, time: .shortened))" }
        return Calendar.current.isDateInToday(event.start) ? time : "Tomorrow \(time)"
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(when).font(.system(size: 11)).foregroundStyle(event.isOngoing(at: now) ? Color.accentColor : .secondary)
            }
            Spacer(minLength: 6)
            if let url = event.joinURL {
                if event.isSoon(at: now) {
                    Button("Join") { join(url) }.buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Button("Join") { join(url) }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }
}
