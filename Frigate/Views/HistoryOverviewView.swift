import SwiftUI

/// Bar strip of motion activity with review items highlighted in their label color.
struct ActivityStrip: View {
    let start: Date
    let end: Date
    let buckets: Int
    let motion: [MotionActivity]
    let reviews: [ReviewItem]
    var height: CGFloat = 26

    var body: some View {
        let bars = computeBars()
        HStack(alignment: .center, spacing: 1) {
            ForEach(bars.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bars[i].color)
                    .frame(maxWidth: .infinity)
                    .frame(height: bars[i].height)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private struct Bar { var height: CGFloat; var color: Color }

    private func computeBars() -> [Bar] {
        let span = end.timeIntervalSince(start)
        let size = span / Double(buckets)
        let now = Date()
        var levels = [Double](repeating: 0, count: buckets)
        for m in motion {
            let i = Int((m.startTime - start.timeIntervalSince1970) / size)
            if i >= 0 && i < buckets { levels[i] = max(levels[i], m.motion ?? 0) }
        }
        var labels = [String?](repeating: nil, count: buckets)
        var severities = [Severity?](repeating: nil, count: buckets)
        for r in reviews {
            let i = Int((r.startTime - start.timeIntervalSince1970) / size)
            guard i >= 0 && i < buckets else { continue }
            // Alerts win over detections in the same bucket.
            if severities[i] == nil || (severities[i] == .detection && r.severity == .alert) {
                severities[i] = r.severity
                labels[i] = r.labels.first
            }
        }
        let maxLevel = max(levels.max() ?? 0, 1)
        return (0..<buckets).map { i in
            let bucketStart = start.addingTimeInterval(Double(i) * size)
            if bucketStart > now { return Bar(height: 2, color: Theme.cardBorder) }
            let norm = levels[i] / maxLevel
            if let label = labels[i] {
                // Height follows motion like the other bars; events keep a minimum so they stay visible.
                let minimum = height * (severities[i] == .alert ? 0.5 : 0.35)
                return Bar(height: max(minimum, CGFloat(norm) * height), color: Theme.labelColor(label))
            }
            return Bar(height: max(2, CGFloat(norm) * height * 0.75), color: levels[i] > 0 ? Theme.motion : Theme.cardBorder)
        }
    }
}

struct HistoryOverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var showDatePicker = false

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                                .frame(width: 32, height: 44, alignment: .leading)
                        }
                        .accessibilityLabel("Back")
                        Text("Recordings").font(.system(size: 28, weight: .bold)).kerning(-0.4)
                        Spacer()
                        Button { showDatePicker = true } label: {
                            Chip(title: FrigateFormat.dayTitle(day), systemImage: "calendar")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Pick date")
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    if model.orderedConnections.count > 1 {
                        HStack { ServerSwitcher(); Spacer() }.padding(.bottom, 4)
                    }

                    ForEach(model.scopedConnections) { conn in
                        ServerHistorySection(conn: conn, day: day)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await model.refreshAll() }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showDatePicker) {
                RecordingCalendarSheet(day: $day, sources: model.scopedConnections.compactMap { c in
                    c.client.map { (client: $0, cameras: Optional<[String]>.none) }
                })
            }
    }
}

struct ServerHistorySection: View {
    let conn: ServerConnection
    let day: Date
    @State private var motion: [String: [MotionActivity]] = [:]
    @State private var reviews: [String: [ReviewItem]] = [:]
    @State private var loading = false

    private var dayEnd: Date { Calendar.current.date(byAdding: .day, value: 1, to: day)! }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ServerBadge(initial: conn.server.initial, tint: conn.server.tint, size: 20)
                Text(conn.server.name.uppercased()).font(.system(size: 13, weight: .bold)).kerning(0.4)
                    .foregroundStyle(Theme.textTertiary)
                Text(conn.isOnline ? L("\(conn.cameras.count) cameras") : L("Offline"))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                if loading { ProgressView().scaleEffect(0.7) }
            }
            .padding(.horizontal, 4)

            if conn.isOnline {
                ForEach(conn.cameras, id: \.name) { cam in
                    NavigationLink(value: PlaybackRoute(serverID: conn.server.id, camera: cam.name, day: day)) {
                        cameraCard(cam)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text(offlineText)
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.controlBorder, style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
        }
        .padding(.top, 10)
        .task(id: "\(day.timeIntervalSince1970)\(conn.isOnline)") { await load() }
    }

    private var offlineText: String {
        if case .connecting = conn.status { return L("Connecting…") }
        if let seen = conn.lastSeen { return L("Offline since \(FrigateFormat.relative(seen).lowercased()). Recordings are not available.") }
        return L("Offline. Recordings are not available.")
    }

    private func cameraCard(_ cam: CameraConfig) -> some View {
        let items = reviews[cam.name] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(cam.displayName).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(L("\(items.count) events"))
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            ActivityStrip(start: day, end: dayEnd, buckets: 72, motion: motion[cam.name] ?? [], reviews: items)
            HStack {
                Text("00:00"); Spacer(); Text("06:00"); Spacer(); Text("12:00"); Spacer(); Text("18:00"); Spacer()
                Text(Calendar.current.isDateInToday(day) ? L("Now") : "24:00")
            }
            .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card(radius: 12)
    }

    private func load() async {
        guard conn.isOnline, let client = conn.client else { return }
        loading = true
        let names = conn.cameras.map(\.name)
        async let m = client.motionActivityByCamera(names, after: day, before: min(dayEnd, Date()), scale: 1200)
        async let r = try? client.reviews(after: day, before: dayEnd, limit: 1000)
        let (motionResult, reviewResult) = await (m, r)
        motion = motionResult
        reviews = Dictionary(grouping: reviewResult ?? []) { $0.camera }
        loading = false
    }
}
