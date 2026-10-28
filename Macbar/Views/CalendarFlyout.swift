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
                Spacer(minLength: 0)
                Button("Back to today") { displayedMonth = Date() }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            .padding(25).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func moveMonth(_ delta: Int) {
        if let date = calendar.date(byAdding: .month, value: delta, to: displayedMonth) { displayedMonth = date }
    }
}
