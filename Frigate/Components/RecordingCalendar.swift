import SwiftUI

/// What is available on each day, keyed by "yyyy-MM-dd".
struct DayAvailability {
    var recordings: Set<String> = []
    var alerts: [String: Int] = [:]
    var detections: [String: Int] = [:]

    mutating func merge(_ other: DayAvailability) {
        recordings.formUnion(other.recordings)
        alerts.merge(other.alerts, uniquingKeysWith: +)
        detections.merge(other.detections, uniquingKeysWith: +)
    }

    static func key(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Last result per set of sources, so the calendar opens filled in; it refreshes behind it.
    @MainActor private static var cache: [String: DayAvailability] = [:]

    static func cacheKey(_ sources: [(client: FrigateClient, cameras: [String]?)]) -> String {
        sources.map { $0.client.baseURL.absoluteString + "|" + ($0.cameras ?? []).sorted().joined(separator: ",") }
            .sorted().joined(separator: ";")
    }

    @MainActor static func cached(_ sources: [(client: FrigateClient, cameras: [String]?)]) -> DayAvailability? {
        cache[cacheKey(sources)]
    }

    /// Loads recording days and event counts for the given cameras on each server.
    @MainActor static func load(_ sources: [(client: FrigateClient, cameras: [String]?)]) async -> DayAvailability {
        let result = await fetch(sources)
        cache[cacheKey(sources)] = result
        return result
    }

    private static func fetch(_ sources: [(client: FrigateClient, cameras: [String]?)]) async -> DayAvailability {
        await withTaskGroup(of: DayAvailability.self) { group in
            for source in sources {
                group.addTask {
                    var a = DayAvailability()
                    async let rec = try? source.client.recordingDays(cameras: source.cameras)
                    async let rev = try? source.client.reviewDays(cameras: source.cameras)
                    let (r, v) = await (rec, rev)
                    a.recordings = r ?? []
                    for (day, counts) in v ?? [:] {
                        a.alerts[day] = counts.totalAlert ?? 0
                        a.detections[day] = counts.totalDetection ?? 0
                    }
                    return a
                }
            }
            var all = DayAvailability()
            for await part in group { all.merge(part) }
            return all
        }
    }
}

/// Month calendar that marks days with recordings and events.
struct RecordingCalendarSheet: View {
    @Binding var day: Date
    let sources: [(client: FrigateClient, cameras: [String]?)]

    @Environment(\.dismiss) private var dismiss
    @State private var month: Date = Date()
    @State private var availability = DayAvailability()
    @State private var loading = true

    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                monthHeader
                weekdayHeader
                grid
                legend
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .navigationTitle("Pick a day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { closePresented(dismiss) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Today") { select(Date()) }
                }
            }
            .background(Theme.background)
        }
        .presentationDetents([.height(520), .large])
        .presentationBackground(Theme.background)
        .task {
            month = calendar.date(from: calendar.dateComponents([.year, .month], from: day)) ?? day
            if let cached = DayAvailability.cached(sources) {
                availability = cached
                loading = false
            }
            availability = await DayAvailability.load(sources)
            loading = false
        }
    }

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous month")
            Spacer()
            HStack(spacing: 8) {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 17, weight: .semibold))
                if loading { ProgressView().scaleEffect(0.7) }
            }
            Spacer()
            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
            }
            .disabled(isCurrentMonth)
            .accessibilityLabel("Next month")
        }
    }

    private var weekdayHeader: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, s in
                Text(s.uppercased()).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        let days = daysInMonth()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                if let date { dayCell(date) } else { Color.clear.frame(height: 48) }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let key = DayAvailability.key(date)
        let hasRecordings = availability.recordings.contains(key)
        let alerts = availability.alerts[key] ?? 0
        let detections = availability.detections[key] ?? 0
        let selected = calendar.isDate(date, inSameDayAs: day)
        let isToday = calendar.isDateInToday(date)
        let future = date > Date()
        let enabled = !future && (hasRecordings || alerts + detections > 0 || loading)

        return Button { select(date) } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 17, weight: selected || isToday ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.onColor : (isToday ? Theme.accent : (hasRecordings ? Theme.text : Theme.textSecondary.opacity(0.45))))
                    .frame(width: 38, height: 38)
                    .background {
                        if selected { Circle().fill(Theme.text) }
                        else if hasRecordings { Circle().fill(Theme.card).overlay(Circle().stroke(Theme.cardBorder, lineWidth: 1)) }
                    }
                HStack(spacing: 3) {
                    if alerts > 0 { Circle().fill(Theme.warning).frame(width: 5, height: 5) }
                    if detections > 0 { Circle().fill(Theme.textSecondary).frame(width: 5, height: 5) }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(accessibility(date, hasRecordings: hasRecordings, alerts: alerts, detections: detections))
    }

    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle().fill(Theme.card).overlay(Circle().stroke(Theme.textSecondary, lineWidth: 1)).frame(width: 12, height: 12)
                Text("Recordings")
            }
            HStack(spacing: 6) { Circle().fill(Theme.warning).frame(width: 7, height: 7); Text("Alerts") }
            HStack(spacing: 6) { Circle().fill(Theme.textSecondary).frame(width: 7, height: 7); Text("Detections") }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func accessibility(_ date: Date, hasRecordings: Bool, alerts: Int, detections: Int) -> String {
        var parts = [date.formatted(date: .complete, time: .omitted)]
        parts.append(hasRecordings ? L("recordings") : L("no recordings"))
        if alerts > 0 { parts.append(L("\(alerts) alerts")) }
        if detections > 0 { parts.append(L("\(detections) detections")) }
        return parts.joined(separator: ", ")
    }

    private var isCurrentMonth: Bool { calendar.isDate(month, equalTo: Date(), toGranularity: .month) }

    private func shiftMonth(_ delta: Int) {
        if let m = calendar.date(byAdding: .month, value: delta, to: month) { month = m }
    }

    private func select(_ date: Date) {
        day = calendar.startOfDay(for: date)
        closePresented(dismiss)
    }

    /// Dates of the month padded with nils so the first lands on its weekday.
    private func daysInMonth() -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) else { return [] }
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var out: [Date?] = Array(repeating: nil, count: leading)
        for d in range {
            out.append(calendar.date(byAdding: .day, value: d - 1, to: first))
        }
        return out
    }
}
