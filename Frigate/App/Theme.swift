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
    var body: some View {
        Text(FrigateFormat.labelName(label))
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(Theme.onLabel)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.labelColor(label), in: RoundedRectangle(cornerRadius: 5))
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
            Text(FrigateFormat.time(ctx.date, seconds: true))
        }
    }
}
