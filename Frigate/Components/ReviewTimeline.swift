import SwiftUI

/// Which review items are on screen, written by the tiles as they scroll and read only by
/// the timeline, so scrolling redraws the timeline and not the grid.
@Observable @MainActor
final class ReviewVisibility {
    private(set) var visible: Set<String> = []

    func set(_ id: String, _ on: Bool) {
        if on { if !visible.contains(id) { visible.insert(id) } } else if visible.contains(id) { visible.remove(id) }
    }

    func reset() { visible = [] }
}

/// Vertical timeline beside the review grid on iPad and Mac, like Frigate's review page:
/// now at the top, every item as a bar as long as it lasted, the part of the day that is in
/// view highlighted. A tap or drag scrolls the grid to that moment.
struct ReviewTimeline: View {
    let entries: [ReviewEntry]
    let visibility: ReviewVisibility
    /// Scroll the grid to this item.
    let onJump: (ReviewEntry) -> Void

    @State private var lastJump: String?

    var body: some View {
        GeometryReader { geo in
            if let range {
                let h = geo.size.height
                ZStack(alignment: .topLeading) {
                    highlight(range, height: h, width: geo.size.width)
                    Canvas { ctx, size in draw(&ctx, size: size, range: range) }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let t = range.upperBound - Double(max(0, min(h, v.location.y)) / h) * (range.upperBound - range.lowerBound)
                    jump(to: t)
                }.onEnded { _ in lastJump = nil })
            }
        }
        .accessibilityHidden(true)
    }

    /// From the oldest loaded item (rounded down to the hour) to now (rounded up).
    private var range: ClosedRange<Double>? {
        guard let oldest = entries.map(\.item.startTime).min() else { return nil }
        let now = Date().timeIntervalSince1970
        let top = (now / 3600).rounded(.up) * 3600
        let bottom = min((oldest / 3600).rounded(.down) * 3600, top - 3600)
        return bottom...top
    }

    private func y(_ t: Double, _ range: ClosedRange<Double>, _ h: CGFloat) -> CGFloat {
        CGFloat((range.upperBound - t) / (range.upperBound - range.lowerBound)) * h
    }

    @ViewBuilder
    private func highlight(_ range: ClosedRange<Double>, height h: CGFloat, width w: CGFloat) -> some View {
        let shown = entries.filter { visibility.visible.contains($0.id) }
        if let newest = shown.map({ $0.item.endTime ?? Date().timeIntervalSince1970 }).max(),
           let oldest = shown.map(\.item.startTime).min() {
            let top = y(newest, range, h), bottom = y(oldest, range, h)
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.accent.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                .frame(width: w, height: max(10, bottom - top + 8))
                .offset(y: top - 4)
                .animation(.easeOut(duration: 0.15), value: top)
        }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, range: ClosedRange<Double>) {
        let h = size.height
        let hours = (range.upperBound - range.lowerBound) / 3600
        // Label every 1, 2, 3, 6 or 12 hours: whatever keeps labels 36 pt or more apart.
        let perHour = h / CGFloat(hours)
        let step = [1.0, 2, 3, 6, 12, 24].first { CGFloat($0) * perHour >= 36 } ?? 24
        let labelX: CGFloat = 2
        let barX = size.width - 14

        var t = range.upperBound
        while t >= range.lowerBound {
            let yy = y(t, range, h)
            let date = Date(timeIntervalSince1970: t)
            let hour = Calendar.current.component(.hour, from: date)
            let major = Double(hour).truncatingRemainder(dividingBy: step) == 0
            var tick = Path()
            tick.move(to: CGPoint(x: barX - (major ? 12 : 6), y: yy))
            tick.addLine(to: CGPoint(x: barX - 3, y: yy))
            ctx.stroke(tick, with: .color(Theme.textTertiary.opacity(major ? 0.8 : 0.4)), lineWidth: 1)
            if major && yy > 6 && yy < h - 6 {
                // At midnight the day, otherwise the hour.
                let text = hour == 0 ? FrigateFormat.shortDay(date) : String(format: "%02d:00", hour)
                ctx.draw(Text(text).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textTertiary),
                         at: CGPoint(x: labelX, y: yy), anchor: .leading)
            }
            t -= 3600
        }

        for entry in entries {
            let item = entry.item
            let top = y(item.endTime ?? Date().timeIntervalSince1970, range, h)
            let bottom = y(item.startTime, range, h)
            let height = max(4, bottom - top)
            let rect = CGRect(x: barX - 3, y: bottom - height, width: 6, height: height)
            let color = item.severity == .alert ? Theme.recording : Theme.warning
            ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(item.hasBeenReviewed ? 0.45 : 1)))
        }
    }

    /// The item that started closest to `t`; only scrolls when that changes.
    private func jump(to t: Double) {
        guard let nearest = entries.min(by: { abs($0.item.startTime - t) < abs($1.item.startTime - t) }),
              nearest.id != lastJump else { return }
        lastJump = nearest.id
        onJump(nearest)
    }
}

/// A review item as a large picture, for the grid on iPad and Mac.
struct ReviewTile: View {
    let entry: ReviewEntry
    let conn: ServerConnection
    var showServer: Bool = true

    var body: some View {
        let item = entry.item
        let camName = conn.config?.cameras[item.camera]?.displayName ?? FrigateFormat.prettyName(item.camera)
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                RemoteImage(url: conn.client?.thumbnailURL(for: item), session: conn.client?.session ?? .shared)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 56)
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    ForEach(item.labels.prefix(4), id: \.self) { LabelIcon(label: $0, size: VideoChip.height) }
                }
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                if !item.hasBeenReviewed {
                    Circle().fill(Theme.accent).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.black.opacity(0.4), lineWidth: 1))
                        .padding(10)
                        .accessibilityLabel("Unreviewed")
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 6) {
                    if showServer { ServerBadge(initial: conn.server.initial, tint: conn.server.tint) }
                    Text(camName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(FrigateFormat.time(item.start)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                    Spacer(minLength: 4)
                    Text(item.inProgress ? "LIVE" : FrigateFormat.reviewDuration(item))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(item.inProgress ? Theme.recording : .black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
