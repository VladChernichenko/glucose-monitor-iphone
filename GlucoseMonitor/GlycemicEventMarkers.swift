import SwiftUI
import Charts

/// Colour families for glycemic events: warm for rise explanations, cool for falls, purple for the
/// insulin-resistance family (stress, late absorption, injection site).
enum GlycemicEventStyle {
    static func color(for event: BackendAPI.GlycemicEvent) -> Color {
        switch event.category {
        case "STRESS", "ABSORPTION_DELAY", "LIPODYSTROPHY": return .purple
        default: return event.isRise ? .orange : .teal
        }
    }
}

/// Pure placement logic for event markers (unit tested).
enum GlycemicEventMarkerLayout {

    struct Pill: Equatable {
        let eventIds: [String]
        let label: String
        let x: CGFloat
        let dashed: Bool
    }

    /// Max pixel gap between two pills before they are drawn separately (same rule as carb chips).
    static let groupingThreshold: CGFloat = 32

    /// The part of an event inside the chart's x-domain, or nil when it lies entirely outside.
    static func clampedSpan(_ event: BackendAPI.GlycemicEvent, domain: ClosedRange<Date>) -> ClosedRange<Date>? {
        let end = max(event.windowEnd, event.onsetAt)
        let lower = max(event.onsetAt, domain.lowerBound)
        let upper = min(end, domain.upperBound)
        return lower <= upper ? lower...upper : nil
    }

    /// Events to draw: not dismissed, and at least partly inside the domain.
    static func visible(_ events: [BackendAPI.GlycemicEvent], in domain: ClosedRange<Date>) -> [BackendAPI.GlycemicEvent] {
        events.filter { $0.state != "DISMISSED" && clampedSpan($0, domain: domain) != nil }
    }

    /// One pill per top-level, non-suppressed event at its (clipped) onset x; pills closer than the
    /// threshold merge into a count pill.
    static func pills(_ items: [(event: BackendAPI.GlycemicEvent, x: CGFloat)]) -> [Pill] {
        let candidates = items.filter { !$0.event.isChild && !$0.event.suppressed }.sorted { $0.x < $1.x }
        var groups: [[(event: BackendAPI.GlycemicEvent, x: CGFloat)]] = []
        for item in candidates {
            if let last = groups.last?.last, item.x - last.x <= groupingThreshold {
                groups[groups.count - 1].append(item)
            } else {
                groups.append([item])
            }
        }
        return groups.map { group in
            let x = group.map(\.x).reduce(0, +) / CGFloat(group.count)
            if group.count == 1 {
                return Pill(eventIds: [group[0].event.id], label: group[0].event.displayLabel, x: x,
                            dashed: group[0].event.isProvisional)
            }
            return Pill(eventIds: group.map(\.event.id), label: "\(group.count) events", x: x, dashed: false)
        }
    }
}

/// Label pills, parent-child connectors and the tap target, drawn over the chart's plot area
/// (a row below the carb chips so the two never collide). iOS 17+ like the note overlay.
struct GlycemicEventPillsOverlay: ViewModifier {
    let events: [BackendAPI.GlycemicEvent]
    let domain: ClosedRange<Date>?
    let onSelect: (BackendAPI.GlycemicEvent) -> Void

    /// Vertical offset of the pill row from the plot's top (carb chips sit at 18).
    private static let pillRowY: CGFloat = 40

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *), let domain {
            content.chartOverlay { proxy in
                GeometryReader { geometry in
                    let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                    let placed: [(event: BackendAPI.GlycemicEvent, x: CGFloat)] = events.compactMap { e in
                        guard let span = GlycemicEventMarkerLayout.clampedSpan(e, domain: domain),
                              let x = proxy.position(forX: span.lowerBound) else { return nil }
                        return (e, plot.minX + x)
                    }

                    // Tap anywhere on a band to open that event.
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .frame(width: plot.width, height: plot.height)
                        .position(x: plot.midX, y: plot.midY)
                        .onTapGesture { location in
                            guard let date: Date = proxy.value(atX: location.x, as: Date.self) else { return }
                            if let hit = events.first(where: { !$0.isChild && $0.onsetAt <= date && date <= $0.windowEnd }) {
                                onSelect(hit)
                            }
                        }

                    // Dotted connector from each child's onset back to its parent's onset.
                    ForEach(placed.filter { $0.event.isChild }, id: \.event.id) { child in
                        if let parent = placed.first(where: { $0.event.id == child.event.linkedEventId }) {
                            Path { p in
                                p.move(to: CGPoint(x: parent.x, y: plot.minY + Self.pillRowY + 12))
                                p.addLine(to: CGPoint(x: child.x, y: plot.minY + Self.pillRowY + 12))
                            }
                            .stroke(GlycemicEventStyle.color(for: parent.event).opacity(0.7),
                                    style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        }
                    }

                    ForEach(GlycemicEventMarkerLayout.pills(placed), id: \.eventIds) { pill in
                        let first = events.first { $0.id == pill.eventIds[0] }
                        Button {
                            if let first { onSelect(first) }
                        } label: {
                            Text(pill.label)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .foregroundStyle(first.map { GlycemicEventStyle.color(for: $0) } ?? .secondary)
                                .background(Capsule().fill(Color(.systemBackground).opacity(0.9)))
                                .overlay(Capsule().strokeBorder(
                                    first.map { GlycemicEventStyle.color(for: $0) } ?? .secondary,
                                    style: StrokeStyle(lineWidth: 1, dash: pill.dashed ? [3, 2] : [])))
                        }
                        .buttonStyle(.plain)
                        .position(x: pill.x, y: plot.minY + Self.pillRowY)
                        .accessibilityLabel(Text(pill.label))
                    }
                }
            }
        } else {
            content
        }
    }
}
