import SwiftUI
import GRDB
import MsngrCore

/// The days of a chat's local history: a calendar day mapped to its first
/// message, built once when the calendar opens. The feed pages the local
/// database, so the calendar covers what the device holds — the same span the
/// reader can scroll to.
enum ChatCalendar {
    struct Days {
        var firstMessageByDay: [Date: String] = [:]
        var span: ClosedRange<Date>?
    }

    /// One row per local day with the id of the day's earliest message; the
    /// grouping day matches the feed's separators, which cut by `sentAt`.
    static func load(_ db: DatabaseQueue, chatId: String) async throws -> Days {
        let rows = try await db.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT strftime('%Y-%m-%d', sentAt, 'unixepoch', 'localtime') AS day,
                       id, MIN(sentAt)
                FROM message WHERE chatId = ?
                GROUP BY day ORDER BY day
                """, arguments: [chatId])
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        var days = Days()
        for row in rows {
            guard let dayText: String = row["day"], let date = fmt.date(from: dayText) else { continue }
            let day = Calendar.current.startOfDay(for: date)
            days.firstMessageByDay[day] = row["id"]
        }
        if let first = days.firstMessageByDay.keys.min(),
           let last = days.firstMessageByDay.keys.max() {
            days.span = first...last
        }
        return days
    }
}

/// The calendar over the history: a month grid where only days that hold
/// messages answer, and picking one lands the feed on that day.
struct ChatCalendarSheet: View {
    let chatId: String
    var onPick: (String) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var days = ChatCalendar.Days()
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start

    private var cal: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: 12) {
            header
            weekdayRow
            monthGrid
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        // the sheet rises over the feed; without an explicit ground the
        // bubbles underneath read through the system material
        .presentationBackground(Color(.systemBackground))
        .accessibilityIdentifier("chat.calendar")
        .task {
            guard let db = app.db else { return }
            days = (try? await ChatCalendar.load(db, chatId: chatId)) ?? ChatCalendar.Days()
            // open on the last month that holds anything
            if let last = days.span?.upperBound,
               let m = cal.dateInterval(of: .month, for: last)?.start {
                month = m
            }
        }
    }

    private var header: some View {
        HStack {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").font(Theme.glyph(17, max: 24))
            }
            .disabled(!canStep(-1))
            .accessibilityIdentifier("calendar.prev")
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
                .contentTransition(.numericText())
            Spacer()
            Button { step(1) } label: {
                Image(systemName: "chevron.right").font(Theme.glyph(17, max: 24))
            }
            .disabled(!canStep(1))
            .accessibilityIdentifier("calendar.next")
        }
        .padding(.horizontal, 8)
    }

    private var weekdayRow: some View {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        // the calendar's own first weekday leads the row, so the grid matches
        // what the system shows everywhere else
        let ordered = (0..<7).map { symbols[($0 + cal.firstWeekday - 1) % 7] }
        return HStack {
            ForEach(Array(ordered.enumerated()), id: \.offset) { pair in
                Text(pair.element)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        let cells = Self.gridDays(month: month, calendar: cal)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { pair in
                if let day = pair.element {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 40)
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let target = days.firstMessageByDay[cal.startOfDay(for: day)]
        let isToday = cal.isDateInToday(day)
        Button {
            guard let target else { return }
            Haptics.light()
            onPick(target)
            dismiss()
        } label: {
            Text("\(cal.component(.day, from: day))")
                .font(.body.weight(target != nil ? .medium : .regular))
                .foregroundStyle(target != nil ? Color.primary : Color.secondary.opacity(0.45))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background {
                    if target != nil {
                        Circle().fill(Theme.accent.opacity(0.14)).frame(width: 38, height: 38)
                    }
                }
                .overlay {
                    if isToday {
                        Circle().strokeBorder(Theme.accent, lineWidth: 1.4)
                            .frame(width: 38, height: 38)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
    }

    /// The month laid out as grid cells: leading nils pad the first week to the
    /// calendar's first weekday.
    static func gridDays(month: Date, calendar cal: Calendar) -> [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: month),
              let dayCount = cal.range(of: .day, in: .month, for: month)?.count else { return [] }
        let firstWeekday = cal.component(.weekday, from: interval.start)
        let lead = (firstWeekday - cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for d in 0..<dayCount {
            cells.append(cal.date(byAdding: .day, value: d, to: interval.start))
        }
        return cells
    }

    private func canStep(_ direction: Int) -> Bool {
        guard let span = days.span,
              let next = cal.date(byAdding: .month, value: direction, to: month) else { return false }
        guard let nextInterval = cal.dateInterval(of: .month, for: next) else { return false }
        return nextInterval.end > cal.startOfDay(for: span.lowerBound)
            && nextInterval.start <= span.upperBound
    }

    private func step(_ direction: Int) {
        guard canStep(direction),
              let next = cal.date(byAdding: .month, value: direction, to: month) else { return }
        withAnimation(Theme.springFast) { month = next }
    }
}
