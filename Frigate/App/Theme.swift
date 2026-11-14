import SwiftUI

/// Localized text from the string catalog. Interpolated values become format arguments,
/// so "\(n) cameras" can have plural forms per language.
func L(_ key: String.LocalizationValue) -> String { String(localized: key) }

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum Theme {
    static let background = Color(hex: 0x0A0B0D)
    static let card = Color(hex: 0x15171B)
    static let cardBorder = Color(hex: 0x23272E)
    static let control = Color(hex: 0x1A1D22)
    static let controlBorder = Color(hex: 0x2A2E35)
    static let placeholder = Color(hex: 0x1A1E24)
    static let segmentSelected = Color(hex: 0x3A3F47)
    static let text = Color(hex: 0xF2F4F7)
    static let textSecondary = Color(hex: 0x9AA3AF)
    static let textTertiary = Color(hex: 0xC9CFD6)
    static let accent = Color(hex: 0x5B9BFF)
    static let online = Color(hex: 0x34C759)
    static let offline = Color(hex: 0x8E8E93)
    static let warning = Color(hex: 0xFF9F43)
    static let destructive = Color(hex: 0xFF6B60)
    static let recording = Color(hex: 0xFF453A)
    static let motion = Color(hex: 0xE5B33E)
    static let onColor = Color(hex: 0x0A0B0D)
    static let onLabel = Color(hex: 0x1A1206)

    static let serverTints: [Color] = [
        Color(hex: 0x5B9BFF), Color(hex: 0x3DD6B5), Color(hex: 0xFFB547),
        Color(hex: 0xFF6B9B), Color(hex: 0xB48CFF), Color(hex: 0x64D2FF),
    ]

    static func tint(_ index: Int) -> Color { serverTints[abs(index) % serverTints.count] }

    static func labelColor(_ label: String) -> Color {
        switch label.lowercased() {
        case "person", "face": return Color(hex: 0xFF9F43)
        case "car", "truck", "motorcycle", "bus", "license_plate": return Color(hex: 0xFFD60A)
        case "dog", "cat", "bird", "horse", "squirrel", "skunk", "deer", "rabbit", "fox": return Color(hex: 0x64D2FF)
        case "package", "amazon", "ups", "fedex", "dhl", "dpd", "gls", "postnl", "usps", "postnord", "an_post", "canada_post", "nzpost":
            return Color(hex: 0x5B9BFF)
        case "bicycle": return Color(hex: 0x3DD6B5)
        case "on_demand": return Color(hex: 0xFF5A5F)
        default:
            if label.hasPrefix("audio:") || ["speech", "bark", "yell", "fire_alarm"].contains(label) {
                return Color(hex: 0xB48CFF)
            }
            return Color(hex: 0xC9CFD6)
        }
    }

    /// Faint tint used behind timeline rows for an event's span.
    static func labelTint(_ label: String) -> Color { labelColor(label).opacity(0.13) }
}

// MARK: - Shared components

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LabelTag: View {
    let label: String
    var size: CGFloat = 11
    /// Fixed height, to line up with other chips on a video (see `VideoChip`).
    var height: CGFloat? = nil
    var body: some View {
        Text(FrigateFormat.labelName(label))
            .font(.system(size: size, weight: .bold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Theme.onLabel)
            .padding(.horizontal, 7)
            .padding(.vertical, height == nil ? 2 : 0)
            .frame(height: height)
            .background(Theme.labelColor(label), in: RoundedRectangle(cornerRadius: height == nil ? 5 : 6))
    }
}

/// Height of the chips on top of a video (time, labels), so they line up.
enum VideoChip {
    static let height: CGFloat = 22
}

/// A label as an icon for common objects (person, car, ...), else as its name.
struct LabelIcon: View {
    let label: String
    var size: CGFloat = 18

    /// SF Symbol for Frigate's labels, including Frigate+ and audio ones; nil for others,
    /// which keep their text. Each label lists alternatives, newest symbol first, so older
    /// iOS versions fall back to one they have.
    static func symbol(for label: String) -> String? {
        let candidates: [String]
        switch label {
        case "person": candidates = ["figure.walk"]
        case "face": candidates = ["face.smiling.inverse", "face.smiling"]
        case "car": candidates = ["car.fill"]
        case "truck": candidates = ["truck.box.fill"]
        case "garbage_truck": candidates = ["truck.box.fill"]
        case "bus", "school_bus": candidates = ["bus.fill"]
        case "motorcycle": candidates = ["motorcycle", "moped.fill"]
        case "bicycle": candidates = ["bicycle"]
        case "on_demand": candidates = ["record.circle.fill"]
        case "boat": candidates = ["sailboat.fill"]
        case "license_plate": candidates = ["123.rectangle.fill"]
        case "package": candidates = ["shippingbox.fill"]
        case "waste_bin": candidates = ["trash.fill"]
        case "robot_lawnmower": candidates = ["leaf.fill"]
        // Delivery vans and couriers recognized by Frigate+.
        case "amazon", "ups", "usps", "fedex", "dhl", "dpd", "gls", "postnl", "postnord", "an_post",
             "purolator", "nzpost", "canada_post", "royal_mail":
            candidates = ["box.truck.fill", "truck.box.fill"]
        case "dog": candidates = ["dog.fill"]
        case "cat": candidates = ["cat.fill"]
        case "bird": candidates = ["bird.fill"]
        case "horse": candidates = ["figure.equestrian.sports", "pawprint.fill"]
        case "rabbit": candidates = ["hare.fill"]
        case "deer", "fox", "skunk", "squirrel", "raccoon", "bear", "kangaroo", "cow", "goat", "sheep":
            candidates = ["pawprint.fill"]
        // Audio labels.
        case "speech", "yell": candidates = ["waveform"]
        case "bark": candidates = ["dog.fill"]
        case "baby_crying": candidates = ["figure.and.child.holdinghands", "waveform"]
        case "fire_alarm": candidates = ["light.beacon.max.fill", "bell.and.waves.left.and.right.fill"]
        case "glass_breaking": candidates = ["burst.fill"]
        default: return nil
        }
        return candidates.first { UIImage(systemName: $0) != nil }
    }

    var body: some View {
        if let symbol = Self.symbol(for: label) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(Theme.onLabel)
                .frame(width: size, height: size)
                .background(Theme.labelColor(label), in: RoundedRectangle(cornerRadius: size * 0.28))
                .accessibilityLabel(FrigateFormat.labelName(label))
        } else {
            LabelTag(label: label, size: max(10, size * 0.58))
                .frame(minHeight: size)
        }
    }
}

struct ServerBadge: View {
    let initial: String
    let tint: Color
    var size: CGFloat = 18
    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.55, weight: .bold))
            .foregroundStyle(Theme.onColor)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.28))
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct CardBackground: ViewModifier {
    var border: Color = Theme.cardBorder
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(border, lineWidth: 1))
    }
}

extension View {
    func card(border: Color = Theme.cardBorder, radius: CGFloat = 14) -> some View {
        modifier(CardBackground(border: border, radius: radius))
    }
}

/// Pill shaped chip used for filters and groups.
struct Chip: View {
    let title: String
    var selected: Bool = false
    var outlined: Bool = false
    var systemImage: String? = nil
    var trailingChevron: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)) }
            Text(title).lineLimit(1)
            if trailingChevron {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.system(size: 14, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? Theme.onColor : (outlined ? Theme.accent : Theme.text))
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(selected ? Theme.accent : Theme.card, in: Capsule())
        .overlay(Capsule().stroke(selected ? .clear : (outlined ? Theme.accent : Theme.controlBorder), lineWidth: 1))
        // Room for the outline: a horizontal scroll view clips at the frame, cutting it in half.
        .padding(1)
    }
}

/// Segmented control styled like the mockups.
struct SegmentedBar<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 14, weight: isOn ? .semibold : .medium))
                        .foregroundStyle(isOn ? Theme.text : Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(isOn ? Theme.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A screen's title. Pushed screens (settings, More) put the back button in front of it on
/// the same line, like Live view's settings; top-level screens show the large title alone.
struct ScreenTitle: View {
    let text: String
    var showsBack = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if showsBack {
            HStack(spacing: 4) {
                // Default button style: the arrow takes the accent color, like on other screens.
                Button { dismiss() } label: { BackButtonLabel() }
                    .accessibilityLabel("Back")
                Text(text).font(.system(size: 28, weight: .bold)).kerning(-0.4).foregroundStyle(Theme.text)
            }
        } else {
            LargeTitle(text: text)
        }
    }
}

struct LargeTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 34, weight: .bold))
            .kerning(-0.5)
            .foregroundStyle(Theme.text)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 34)).foregroundStyle(Theme.textSecondary)
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            if let message {
                Text(message).font(.system(size: 14)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// A settings row with a switch. The whole row toggles on tap: a plain Toggle inside a
/// ScrollView does not respond to taps on iOS 27.
struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Button { set(!isOn) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Toggle("", isOn: .constant(isOn))
                    .labelsHidden()
                    .tint(Theme.online)
                    .allowsHitTesting(false)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? L("On") : L("Off"))
    }
}

/// Re-renders its content only when `key` changes. Wrap menus in it on screens that update
/// many times per second (playback time, clocks): an open Menu flickers when it is rebuilt.
struct Stable<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    @ViewBuilder let content: () -> Content

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    var body: some View { content() }
}

extension Stable {
    /// Use with `.equatable()` so SwiftUI compares the key before rebuilding.
    func stable() -> some View { self.equatable() }
}

/// A clock that ticks on its own, so its parent does not redraw every second.
struct ClockLabel: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(FrigateFormat.time(ScreenshotMode.liveTime.map { Date(timeIntervalSince1970: $0) } ?? ctx.date, seconds: true))
        }
    }
}

/// Whether a context menu (SwiftUI `Menu`) is currently shown anywhere in the app.
/// SwiftUI gives no callback for that; the presented menu lives in its own container view.
enum MenuPresence {
    @MainActor static var isShowing: Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for window in ws.windows where !window.isHidden {
                if contains(window, depth: 0) { return true }
            }
        }
        return false
    }

    @MainActor private static func contains(_ view: UIView, depth: Int) -> Bool {
        if depth > 6 { return false }
        if String(describing: type(of: view)).contains("ContextMenu") { return true }
        return view.subviews.contains { contains($0, depth: depth + 1) }
    }
}

/// The back button's look. On iPad and Mac an arrow on a raised square, like Frigate's own
/// web app: a bare chevron was easy to miss there. On the phone the usual bare chevron.
struct BackButtonLabel: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            Image(systemName: "arrow.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 40, height: 40)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.controlBorder, lineWidth: 1))
                // No extra width: the square's edge lines up with the content below.
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        } else {
            // On the content's edge, like the titles below it.
            Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
    }
}

/// A button in a screen's top bar beside the back button: the same raised square on iPad and
/// Mac, a bare icon on the phone.
struct HeaderIconLabel: View {
    let systemName: String
    /// A spinner in place of the icon, same size, while the button's work runs.
    var loading = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    @ViewBuilder private var icon: some View {
        if loading {
            ProgressView().tint(Theme.text)
        } else {
            Image(systemName: systemName)
        }
    }

    var body: some View {
        if sizeClass == .regular {
            icon
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 40, height: 40)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.controlBorder, lineWidth: 1))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        } else {
            icon.font(.system(size: 19, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 44, alignment: .trailing)
                .contentShape(Rectangle())
        }
    }
}

extension View {
    /// Side margins of a screen's top bar: its buttons line up with the content's 16 pt margin.
    func headerBarPadding() -> some View { padding(.horizontal, 16) }
}


extension View {
    /// Fades controls in and out. They stay in the view tree while hidden: removing them
    /// skipped the fade-out (the video under them redraws every frame).
    /// `pointerOver` is set while the pointer rests on them, so they are not hidden then.
    @ViewBuilder
    func fadingControls(_ visible: Bool, pointerOver: Binding<Bool>? = nil) -> some View {
        let faded = opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            // Hidden buttons are off, so they neither take the pointer nor show a hand cursor.
            .disabled(!visible)
            .accessibilityHidden(!visible)
            .animation(.easeOut(duration: 0.25), value: visible)
        // Only with a binding: a hover handler takes the pointer even while hidden, and the
        // video under a full-screen overlay then never hears the mouse move.
        if let pointerOver {
            faded.onHover { inside in pointerOver.wrappedValue = inside && visible }
        } else {
            faded
        }
    }

    /// Reports when the pointer rests on this part of a full-screen overlay (its own frame,
    /// not the whole screen the overlay covers).
    func pointerOver(_ flag: Binding<Bool>) -> some View {
        onHover { flag.wrappedValue = $0 }
    }
}

/// "4 h ago" that stays right: redrawn every minute and when the app comes back, not only
/// when the data around it changes.
struct RelativeTimeText: View {
    let date: Date

    var body: some View {
        TimelineView(.everyMinute) { _ in Text(FrigateFormat.relative(date)) }
    }
}


/// A delete item in a menu: red icon as well as red text. The app-wide accent tint otherwise
/// colours the icon blue next to the red title.
struct DestructiveMenuLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "trash").foregroundStyle(Theme.destructive)
        }
        .tint(Theme.destructive)
    }
}

/// Closes the sheet or full-screen cover this view is in. On the Mac a SwiftUI `dismiss` (or
/// setting the presenting state to false) took effect only once the window lost focus, while
/// Esc, which UIKit handles, closed it at once; so on the Mac it closes the way Esc does.
/// Outside a sheet (a screen pushed on a stack) it is the ordinary `dismiss`.
@MainActor
func closePresented(_ dismiss: DismissAction) {
    #if targetEnvironment(macCatalyst)
    let root = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
        .first
    if var top = root {
        while let next = top.presentedViewController { top = next }
        if top.presentingViewController != nil {
            top.dismiss(animated: true)
            return
        }
    }
    #endif
    dismiss()
}
