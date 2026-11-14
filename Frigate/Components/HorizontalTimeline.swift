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
    /// A drag that turned out to be a click: drop the scrub preview without seeking.
    var onScrubCancel: () -> Void = {}
    /// A tap on an event's icon above the bars; nil leaves out the icon row.
    var onSelect: ((ReviewItem) -> Void)? = nil

    /// Seconds per point; owned by the parent so its zoom buttons can change it.
    @Binding var scale: Double
    @State private var pinchBase: Double?
    @State private var dragStartTime: Double?
    @State private var fling = TimelineFling()
    /// Where a trackpad scroll has got to.
    @State private var scrollTime: Double?

    private let barWidth: CGFloat = 3
    private let barArea: CGFloat = 30
    /// Row of event icons between the time labels and the bars.
    private var iconRow: CGFloat { onSelect == nil ? 0 : 22 }
    private let iconSize: CGFloat = 18

    var body: some View {
        Canvas { ctx, size in draw(ctx, size: size) }
            .frame(height: barArea + 22 + iconRow)
            .contentShape(Rectangle())
            // Two fingers on a trackpad: the same as dragging, with the same follow-through.
            .overlay {
                TrackpadScroll(
                    onBegan: { onInteract(); fling.cancel(); dragStartTime = wallTime; scrollTime = wallTime },
                    onChanged: { p in
                        let t = clamp((dragStartTime ?? wallTime) - Double(p.x) * scale)
                        scrollTime = t
                        onScrub(t)
                    },
                    onEnded: { v in
                        let released = scrollTime ?? wallTime
                        dragStartTime = nil
                        scrollTime = nil
                        let snap = scale * 24
                        if abs(v.x) > TimelineFling.minimumSpeed {
                            fling.start(from: released, velocity: -Double(v.x) * scale, clamp: clamp,
                                        step: onScrub, end: { onScrubEnd($0, snap) })
                        } else {
                            onScrubEnd(released, snap)
                        }
                    })
            }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in
                    onInteract()
                    if dragStartTime == nil { fling.cancel() }
                    let base = dragStartTime ?? wallTime
                    if dragStartTime == nil { dragStartTime = base }
                    // Dragging right moves back in time.
                    onScrub(clamp(base - Double(v.translation.width) * scale))
                }
                .onEnded { v in
                    let base = dragStartTime ?? wallTime
                    dragStartTime = nil
                    // A click that moved a few points (usual on a trackpad) is still a click:
                    // go back to where it started and handle it as one.
                    if abs(v.translation.width) < 6 && abs(v.translation.height) < 6 {
                        onScrubCancel()
                        tap(at: v.startLocation)
                        return
                    }
                    let released = clamp(base - Double(v.translation.width) * scale)
                    // A quick swipe keeps going, like scrolling.
                    if abs(v.velocity.width) > TimelineFling.minimumSpeed {
                        let snap = scale * 24
                        fling.start(from: released, velocity: -Double(v.velocity.width) * scale, clamp: clamp,
                                    step: onScrub, end: { onScrubEnd($0, snap) })
                    } else {
                        onScrubEnd(released, scale * 24)
                    }
                })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    onInteract()
                    let base = pinchBase ?? scale
                    if pinchBase == nil { pinchBase = base }
                    scale = min(max(base / v.magnification, Self.minScale), Self.maxScale)
                }
                .onEnded { _ in pinchBase = nil })
            // Its width, for turning a tap's x into a time (a preference here never arrived).
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onTapGesture { p in tap(at: p) }
    }

    /// A tap or click: on an event's icon plays that event, elsewhere moves there.
    private func tap(at p: CGPoint) {
        onInteract()
        if let onSelect, p.y >= 14, p.y <= 22 + iconRow, let r = review(atX: p.x) {
            onSelect(r)
            return
        }
        onScrubEnd(clamp(wallTime + Double(p.x - width / 2) * scale), scale * 24)
    }

    @State private var width: CGFloat = 0

    static let minScale = 0.25, maxScale = 30.0

    private func clamp(_ t: Double) -> Double { min(max(t, dayStart), dayEnd) }

    /// Most motion in buckets starting in `from..<to`. `motion` is sorted by start time, so a
    /// binary search finds the first one; filtering the whole day per bar made dragging slow.
    private func motionLevel(from: Double, to: Double) -> Double {
        var lo = 0, hi = motion.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if motion[mid].startTime < from { lo = mid + 1 } else { hi = mid }
        }
        var best = 0.0
        while lo < motion.count, motion[lo].startTime < to {
            best = max(best, motion[lo].motion ?? 0)
            lo += 1
        }
        return best
    }

    /// The event whose icon is under `x`, if any.
    private func review(atX x: CGFloat) -> ReviewItem? {
        iconPositions(width: width).min { abs($0.x - x) < abs($1.x - x) }.flatMap { abs($0.x - x) <= iconSize ? $0.review : nil }
    }

    /// Where event icons go: at each event's start, leaving out icons that would overlap.
    private func iconPositions(width: CGFloat) -> [(x: CGFloat, review: ReviewItem)] {
        let center = width / 2
        var out: [(x: CGFloat, review: ReviewItem)] = []
        var lastX = -CGFloat.infinity
        for r in reviews.sorted(by: { $0.startTime < $1.startTime }) {
            let x = center + CGFloat((r.startTime - wallTime) / scale)
            guard x > -iconSize, x < width + iconSize else { continue }
            guard x - lastX >= iconSize + 3 else { continue }
            out.append((x, r))
            lastX = x
        }
        return out
    }

    private func drawIcons(_ ctx: GraphicsContext, size: CGSize) {
        for (x, r) in iconPositions(width: size.width) {
            let label = r.labels.first ?? ""
            let box = CGRect(x: x - iconSize / 2, y: 20, width: iconSize, height: iconSize)
            ctx.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(Theme.labelColor(label)))
            if let symbol = LabelIcon.symbol(for: label) {
                var img = ctx.resolve(Image(systemName: symbol))
                img.shading = .color(Theme.onLabel)
                let k = 11 / max(img.size.width, img.size.height)
                let w = img.size.width * k, h = img.size.height * k
                ctx.draw(img, in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
            } else {
                let letter = ctx.resolve(Text(String(FrigateFormat.labelName(label).prefix(1)))
                    .font(.system(size: 11, weight: .bold)).foregroundColor(Theme.onLabel))
                ctx.draw(letter, at: CGPoint(x: box.midX, y: box.midY))
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        if onSelect != nil { drawIcons(ctx, size: size) }
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
            if map.hasRecording(from: t, to: t + step) {
                ctx.fill(Path(CGRect(x: x, y: baseline - 2, width: barWidth, height: 2)), with: .color(Theme.accent.opacity(0.7)))
            }
            if let r = reviews.first(where: { t + step > $0.startTime && t < ($0.endTime ?? dayEnd) }) {
                // As in Frigate: the event as a tinted band, the motion in it still as a waveform
                // (in the event's color). Full bars hid how much was going on.
                let color = Theme.labelColor(r.labels.first ?? "")
                ctx.fill(Path(CGRect(x: x, y: barBase - barArea, width: barWidth, height: barArea)), with: .color(color.opacity(0.14)))
                let level = motionLevel(from: t - 15, to: t + step)
                let h = max(4, CGFloat(level / maxMotion) * barArea * 0.8)
                ctx.fill(Path(roundedRect: CGRect(x: x, y: barBase - h, width: barWidth - 1, height: h), cornerRadius: 1),
                         with: .color(color))
            } else if map.hasRecording(from: t, to: t + step) {
                let level = motionLevel(from: t - 15, to: t + step)
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

/// Keeps a timeline moving after the finger lets go, slowing down like an iOS scroll view.
/// A new touch stops it.
@MainActor
final class TimelineFling {
    private var task: Task<Void, Never>?

    /// Points per second below which a release just stops.
    static let minimumSpeed: CGFloat = 300

    /// `velocity` is in timeline seconds per second. Calls `step` every frame with the new
    /// time and `end` once with where it came to rest.
    func start(from time: Double, velocity: Double, clamp: @escaping (Double) -> Double,
               step: @escaping (Double) -> Void, end: @escaping (Double) -> Void) {
        cancel()
        task = Task { @MainActor in
            var t = time, v = velocity
            let frame = 1.0 / 60
            // UIScrollView's normal deceleration: speed drops 0.2 % every millisecond.
            let decay = pow(0.998, frame * 1000)
            while abs(v) * frame > 0.0001, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(frame))
                if Task.isCancelled { return }
                let next = clamp(t + v * frame)
                if next == t { break } // hit the start or end of the day
                t = next
                v *= decay
                step(t)
                if abs(v) < abs(velocity) * 0.02 { break }
            }
            if !Task.isCancelled { end(t) }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Catches two-finger trackpad scrolling (and a mouse wheel) over a timeline, which SwiftUI's
/// drag gestures never see. Touches and clicks pass straight through to the views below.
struct TrackpadScroll: UIViewRepresentable {
    var onBegan: () -> Void
    var onChanged: (CGPoint) -> Void
    /// Velocity in points per second at release.
    var onEnded: (CGPoint) -> Void

    func makeUIView(context: Context) -> ScrollView {
        let view = ScrollView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.allowedScrollTypesMask = .all
        pan.allowedTouchTypes = []
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ view: ScrollView, context: Context) { context.coordinator.parent = self }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class ScrollView: UIView {
        // Only scroll events land here; everything else goes to what is underneath.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            event?.type == .scroll && bounds.contains(point) ? self : nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TrackpadScroll
        init(parent: TrackpadScroll) { self.parent = parent }

        // Scrolling the timeline wins: the navigation's swipe back (two fingers sideways)
        // and scroll views around it wait for this one to fail. Only other scroll gestures:
        // a mouse drag on the timeline itself (its own drag gesture) must not wait, or it moves
        // only once the button is let go.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard let pan = other as? UIPanGestureRecognizer else { return false }
            return !pan.allowedScrollTypesMask.isEmpty
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began: parent.onBegan(); parent.onChanged(g.translation(in: g.view))
            case .changed: parent.onChanged(g.translation(in: g.view))
            case .ended: parent.onEnded(g.velocity(in: g.view))
            case .cancelled, .failed: parent.onEnded(.zero)
            default: break
            }
        }
    }
}
