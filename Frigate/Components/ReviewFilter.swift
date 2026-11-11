import SwiftUI

/// Client-side filter for review items by type, label and zone.
struct ReviewFilter: Equatable {
    var severity: Severity? = nil
    var labels: Set<String> = []
    var zones: Set<String> = []

    var isActive: Bool { severity != nil || !labels.isEmpty || !zones.isEmpty }

    func matches(_ item: ReviewItem) -> Bool {
        if let severity, item.severity != severity { return false }
        if !labels.isEmpty, labels.isDisjoint(with: item.labels) { return false }
        if !zones.isEmpty, zones.isDisjoint(with: item.data.zones ?? []) { return false }
        return true
    }
}

/// Chips for filtering review items: type, labels and zones.
struct ReviewFilterBar: View {
    @Binding var filter: ReviewFilter
    /// Items used to offer the labels and zones that actually occur.
    let reviews: [ReviewItem]
    /// Zones configured on the camera, offered even when nothing happened there yet.
    var zones: [String] = []

    private var labelOptions: [String] {
        var set = Set(reviews.flatMap(\.labels))
        set.formUnion(filter.labels)
        return set.sorted()
    }

    private var zoneOptions: [String] {
        var set = Set(reviews.flatMap { $0.data.zones ?? [] })
        set.formUnion(zones)
        set.formUnion(filter.zones)
        return set.sorted()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    option(L("All types"), filter.severity == nil) { filter.severity = nil }
                    option(L("Alerts"), filter.severity == .alert) { filter.severity = .alert }
                    option(L("Detections"), filter.severity == .detection) { filter.severity = .detection }
                } label: {
                    Chip(title: filter.severity == nil ? L("Type") : (filter.severity == .alert ? L("Alerts") : L("Detections")),
                         outlined: filter.severity != nil, trailingChevron: true)
                }
                Menu {
                    option(L("All labels"), filter.labels.isEmpty) { filter.labels = [] }
                    ForEach(labelOptions, id: \.self) { l in
                        option(FrigateFormat.labelName(l).capitalizedFirst, filter.labels.contains(l)) { toggle(&filter.labels, l) }
                    }
                } label: {
                    Chip(title: filter.labels.isEmpty ? L("Labels") : filter.labels.map(FrigateFormat.labelName).sorted().joined(separator: ", "),
                         outlined: !filter.labels.isEmpty, trailingChevron: true)
                }
                .disabled(labelOptions.isEmpty)
                Menu {
                    option(L("All zones"), filter.zones.isEmpty) { filter.zones = [] }
                    ForEach(zoneOptions, id: \.self) { z in
                        option(FrigateFormat.prettyName(z), filter.zones.contains(z)) { toggle(&filter.zones, z) }
                    }
                } label: {
                    Chip(title: filter.zones.isEmpty ? L("Zones") : filter.zones.map(FrigateFormat.prettyName).sorted().joined(separator: ", "),
                         outlined: !filter.zones.isEmpty, trailingChevron: true)
                }
                .disabled(zoneOptions.isEmpty)
                if filter.isActive {
                    Button { filter = ReviewFilter() } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 34, height: 34)
                            .background(Theme.card, in: Circle())
                            .overlay(Circle().stroke(Theme.controlBorder, lineWidth: 1))
                    }
                    .accessibilityLabel("Clear filters")
                }
            }
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ set: inout Set<String>, _ value: String) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    @ViewBuilder
    private func option(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if on { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}
