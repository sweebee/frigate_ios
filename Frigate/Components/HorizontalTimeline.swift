import SwiftUI

/// Horizontal timeline for landscape playback, in the style of NVR apps: the playhead sits in
/// the middle and the day slides underneath. Bars show motion; events are drawn in their label
/// color. Drag to scrub, pinch or use the buttons to zoom, tap to jump.
struct HorizontalTimeline: View {
    let dayStart: Double
    let dayEnd: Double
    let wallTime: Double
    let motion: [MotionActivity]
    let reviews: [ReviewItem]
    let map: RecordingMap
    let onScrub: (Double) -> Void
    /// Release time plus a snap window in seconds (about 24 points at the current zoom).
    let onScrubEnd: (Double, Double) -> Void
    /// Called on any touch so the surrounding overlay can stay visible.
    var onInteract: () -> Void = {}

    /// Seconds per point; owned by the parent so its zoom buttons can change it.
    @Binding var scale: Double
    @State private var pinchBase: Double?
    @State private var dragStartTime: Double?

    private let barWidth: CGFloat = 3
    private let barArea: CGFloat = 30

    var body: some View {
        Canvas { ctx, size in draw(ctx, size: size) }
            .frame(height: barArea + 22)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in
                    onInteract()
                    let base = dragStartTime ?? wallTime
                    if dragStartTime == nil { dragStartTime = base }
                    // Dragging right moves back in time.
                    onScrub(clamp(base - Double(v.translation.width) * scale))
                }
                .onEnded { v in
                    let base = dragStartTime ?? wallTime
                    dragStartTime = nil
                    onScrubEnd(clamp(base - Double(v.translation.width) * scale), scale * 24)
                })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    onInteract()
                    let base = pinchBase ?? scale
                    if pinchBase == nil { pinchBase = base }
                    scale = min(max(base / v.magnification, Self.minScale), Self.maxScale)
                }
                .onEnded { _ in pinchBase = nil })
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: WidthKey.self, value: geo.size.width)
                }
            }
            .onPreferenceChange(WidthKey.self) { width = $0 }
            .onTapGesture { p in
                onInteract()
                onScrubEnd(clamp(wallTime + Double(p.x - width / 2) * scale), scale * 24)
            }
    }

    @State private var width: CGFloat = 0
    private struct WidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    static let minScale = 0.25, maxScale = 30.0

    private func clamp(_ t: Double) -> Double { min(max(t, dayStart), dayEnd) }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        let center = size.width / 2
        let step = Double(barWidth) * scale
        let maxMotion = max(motion.map { $0.motion ?? 0 }.max() ?? 1, 1)
        let baseline = size.height
        let barBase = baseline - 4
        // Align buckets to multiples of `step` so bars do not shimmer while playing.
        let leftTime = wallTime - Double(center) * scale
        let firstBucket = (leftTime / step).rounded(.down) * step
        var t = firstBucket
        while true {
            let x = center + CGFloat((t - wallTime) / scale)
            if x > size.width { break }
            defer { t += step }
            guard t + step > dayStart, t < dayEnd else { continue }
            let mid = t + step / 2
            // Blue line under the bars where video was recorded, so gaps are visible.
            if map.hasRecording(at: mid) {
                ctx.fill(Path(CGRect(x: x, y: baseline - 2, width: barWidth, height: 2)), with: .color(Theme.accent.opacity(0.7)))
            }
            if let r = reviews.first(where: { t + step > $0.startTime && t < ($0.endTime ?? dayEnd) }) {
                let h = barArea
                ctx.fill(Path(roundedRect: CGRect(x: x, y: barBase - h, width: barWidth - 1, height: h), cornerRadius: 1),
                         with: .color(Theme.labelColor(r.labels.first ?? "")))
            } else if map.hasRecording(at: mid) {
                let level = motion.filter { $0.startTime >= t - 15 && $0.startTime < t + step }.map { $0.motion ?? 0 }.max() ?? 0
                let h = max(3, CGFloat(level / maxMotion) * barArea * 0.8)
                ctx.fill(Path(roundedRect: CGRect(x: x, y: barBase - h, width: barWidth - 1, height: h), cornerRadius: 1),
                         with: .color(level > 0 ? Theme.motion.opacity(0.75) : Theme.controlBorder))
            }
        }

        // Time labels roughly every 110 points.
        let candidates: [Double] = [30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800]
        let interval = candidates.first { $0 / scale >= 110 } ?? 21600
        var lt = (leftTime / interval).rounded(.up) * interval
        while true {
            let x = center + CGFloat((lt - wallTime) / scale)
            if x > size.width { break }
            if lt >= dayStart && lt <= dayEnd + interval {
                ctx.fill(Path(CGRect(x: x, y: 13, width: 1, height: 4)), with: .color(Theme.textSecondary))
                let text = Text(FrigateFormat.time(Date(timeIntervalSince1970: lt)))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Theme.textSecondary)
                ctx.draw(text, at: CGPoint(x: x, y: 5), anchor: .center)
            }
            lt += interval
        }
    }
}
