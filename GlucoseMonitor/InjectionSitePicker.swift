import SwiftUI

/// A body zone for insulin injections (spec F7). Geometry is in a 120 x 250 body space, the same
/// layout as the Glucose Twin page, so the map looks the way it always has. Left/right are the
/// user's own sides: on the front view their right side is on the left of the picture.
struct InjectionZone: Identifiable, Equatable {
    enum View { case front, back }

    let code: String
    let label: String
    let view: View
    let rect: CGRect

    var id: String { code }

    static let unknown = "unknown"

    static let all: [InjectionZone] = [
        .init(code: "abd_ur", label: "Belly, upper right", view: .front, rect: CGRect(x: 38, y: 84, width: 21, height: 18)),
        .init(code: "abd_ul", label: "Belly, upper left", view: .front, rect: CGRect(x: 61, y: 84, width: 21, height: 18)),
        .init(code: "abd_lr", label: "Belly, lower right", view: .front, rect: CGRect(x: 38, y: 106, width: 21, height: 18)),
        .init(code: "abd_ll", label: "Belly, lower left", view: .front, rect: CGRect(x: 61, y: 106, width: 21, height: 18)),
        .init(code: "thigh_r", label: "Thigh, right front", view: .front, rect: CGRect(x: 38, y: 150, width: 19, height: 42)),
        .init(code: "thigh_l", label: "Thigh, left front", view: .front, rect: CGRect(x: 63, y: 150, width: 19, height: 42)),
        .init(code: "arm_l", label: "Arm, left (back)", view: .back, rect: CGRect(x: 9, y: 58, width: 15, height: 34)),
        .init(code: "arm_r", label: "Arm, right (back)", view: .back, rect: CGRect(x: 96, y: 58, width: 15, height: 34)),
        .init(code: "flank_l", label: "Flank, left", view: .back, rect: CGRect(x: 31, y: 96, width: 16, height: 22)),
        .init(code: "flank_r", label: "Flank, right", view: .back, rect: CGRect(x: 73, y: 96, width: 16, height: 22)),
        .init(code: "butt_l", label: "Buttock, left upper-outer", view: .back, rect: CGRect(x: 33, y: 126, width: 24, height: 20)),
        .init(code: "butt_r", label: "Buttock, right upper-outer", view: .back, rect: CGRect(x: 63, y: 126, width: 24, height: 20)),
    ]

    static func label(for code: String?) -> String? {
        guard let code else { return nil }
        if code == unknown { return "Not remembered" }
        return all.first { $0.code == code }?.label
    }
}

/// Pure rotation helpers for the picker (unit tested).
enum InjectionSiteRules {
    static let repeatLimit = 3

    /// Picking `zone` makes it the same body zone `repeatLimit` times in a row. `recent` is newest first;
    /// "unknown" answers and the dose being answered are skipped.
    static func wouldRepeat(_ zone: String, recent: [BackendAPI.InjectionSites.Recent], excluding noteId: String) -> Bool {
        let previous = recent.filter { $0.noteId != noteId && $0.zone != InjectionZone.unknown }.prefix(repeatLimit - 1)
        return previous.count == repeatLimit - 1 && previous.allSatisfy { $0.zone == zone }
    }
}

/// "Where did you inject?" after an insulin dose: a front/back body map coloured by recent use, with
/// the suggested next zone outlined. Saving stores the zone on the dose's note.
struct InjectionSitePickerSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let note: BackendAPI.GlucoseNote

    @State private var sites: BackendAPI.InjectionSites?
    @State private var selected: String?
    @State private var saving = false
    @State private var failed = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var doseLine: String {
        let units = note.insulin.rounded() == note.insulin ? String(Int(note.insulin)) : String(format: "%.1f", note.insulin)
        let kind = note.isLongActing ? note.meal : "rapid insulin"
        let time = note.timestamp.map { " at \(Self.timeFormatter.string(from: $0))" } ?? ""
        return "\(units) U \(kind)\(time)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(doseLine).font(.subheadline).foregroundStyle(.secondary)

                    if let warning = sites?.warning {
                        Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        figure(.front, title: "Front")
                        figure(.back, title: "Back")
                    }

                    legend

                    if let selected, let label = InjectionZone.label(for: selected) {
                        Text(label).font(.headline)
                        if InjectionSiteRules.wouldRepeat(selected, recent: sites?.recent ?? [], excluding: note.id) {
                            Label("Rotate: this would be the same spot \(InjectionSiteRules.repeatLimit) times in a row. Repeated use causes lumps that absorb insulin unpredictably.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    } else if let suggested = sites?.suggested, let label = InjectionZone.label(for: suggested) {
                        Text("Suggested next: \(label.lowercased())").font(.footnote).foregroundStyle(.secondary)
                    }

                    if failed {
                        Text("Couldn't save the site. Try again.").font(.footnote).foregroundStyle(.red)
                    }

                    Button {
                        if let selected { Task { await save(selected) } }
                    } label: {
                        Text("Save").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil || saving)

                    Button {
                        Task { await save(InjectionZone.unknown) }
                    } label: {
                        Text("Don't remember").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(saving)
                }
                .padding()
            }
            .navigationTitle("Where did you inject?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip") { dismiss() } }
            }
            .task { sites = try? await BackendAPI.fetchInjectionSites(rapid: !note.isLongActing) }
        }
    }

    private func figure(_ view: InjectionZone.View, title: String) -> some View {
        VStack(spacing: 4) {
            BodyMapView(view: view, sites: sites, selected: selected) { selected = $0 }
            Text(title.uppercased()).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(BodyMapView.recentColor, "Used < 24 h")
            legendItem(BodyMapView.warmColor, "24–72 h")
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.teal, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .frame(width: 12, height: 12)
                Text("Suggested")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
            Text(text)
        }
    }

    private func save(_ zone: String) async {
        saving = true
        failed = false
        defer { saving = false }
        if await appState.recordInjectionSite(noteId: note.id, zone: zone) {
            dismiss()
        } else {
            failed = true
        }
    }
}

/// One body view (front or back) with tappable zones.
struct BodyMapView: View {
    static let recentColor = Color.red.opacity(0.45)
    static let warmColor = Color.orange.opacity(0.35)
    private static let space = CGSize(width: 120, height: 250)

    let view: InjectionZone.View
    let sites: BackendAPI.InjectionSites?
    let selected: String?
    let onPick: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / Self.space.width
            ZStack(alignment: .topLeading) {
                BodySilhouette().fill(Color(.systemGray5))
                BodySilhouette().stroke(Color(.systemGray3), lineWidth: 1)
                ForEach(InjectionZone.all.filter { $0.view == view }) { zone in
                    zoneShape(zone, scale: s)
                }
                sideLabels(scale: s)
            }
        }
        .aspectRatio(Self.space.width / Self.space.height, contentMode: .fit)
        .frame(maxWidth: 170)
    }

    private func zoneShape(_ zone: InjectionZone, scale s: CGFloat) -> some View {
        let isSelected = selected == zone.code
        let isSuggested = selected == nil && sites?.suggested == zone.code
        let shape = RoundedRectangle(cornerRadius: 5 * s)
        return shape
            .fill(isSelected ? Color.teal : fill(for: zone.code))
            .overlay(shape.strokeBorder(Color.teal,
                                        style: StrokeStyle(lineWidth: isSuggested ? 2 : 1.2, dash: isSuggested ? [3, 2] : [])))
            .frame(width: zone.rect.width * s, height: zone.rect.height * s)
            .contentShape(shape)
            .onTapGesture { onPick(zone.code) }
            .position(x: zone.rect.midX * s, y: zone.rect.midY * s)
            .accessibilityElement()
            .accessibilityLabel(zone.label)
            .accessibilityValue(accessibilityStatus(zone.code))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func fill(for code: String) -> Color {
        switch sites?.zones.first(where: { $0.zone == code })?.status {
        case "USED_24H": return Self.recentColor
        case "USED_72H": return Self.warmColor
        default: return Color(.systemBackground)
        }
    }

    private func accessibilityStatus(_ code: String) -> String {
        switch sites?.zones.first(where: { $0.zone == code })?.status {
        case "USED_24H": return "used in the last 24 hours"
        case "USED_72H": return "used in the last 3 days"
        default: return sites?.suggested == code ? "suggested" : ""
        }
    }

    private func sideLabels(scale s: CGFloat) -> some View {
        // Front: the user's right side is on the picture's left; back: their left is on the left.
        let left = view == .front ? "R" : "L", right = view == .front ? "L" : "R"
        return ZStack {
            Text(left).position(x: 8 * s, y: 242 * s)
            Text(right).position(x: 112 * s, y: 242 * s)
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
        .allowsHitTesting(false)
    }
}

/// A simple body outline in the 120 x 250 body space, scaled to the view.
private struct BodySilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 120
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.addEllipse(in: CGRect(origin: p(47, 7), size: CGSize(width: 26 * s, height: 26 * s)))
        path.addRect(CGRect(origin: p(54, 31), size: CGSize(width: 12 * s, height: 9 * s)))
        // Torso
        path.move(to: p(30, 42))
        path.addQuadCurve(to: p(90, 42), control: p(60, 36))
        path.addLine(to: p(94, 128))
        path.addQuadCurve(to: p(26, 128), control: p(60, 138))
        path.closeSubpath()
        // Arms
        path.move(to: p(30, 44)); path.addLine(to: p(18, 50)); path.addLine(to: p(8, 122))
        path.addLine(to: p(19, 124)); path.addLine(to: p(28, 66)); path.closeSubpath()
        path.move(to: p(90, 44)); path.addLine(to: p(102, 50)); path.addLine(to: p(112, 122))
        path.addLine(to: p(101, 124)); path.addLine(to: p(92, 66)); path.closeSubpath()
        // Legs
        path.move(to: p(30, 128)); path.addLine(to: p(60, 132)); path.addLine(to: p(58, 244))
        path.addLine(to: p(40, 244)); path.closeSubpath()
        path.move(to: p(90, 128)); path.addLine(to: p(60, 132)); path.addLine(to: p(62, 244))
        path.addLine(to: p(80, 244)); path.closeSubpath()
        return path
    }
}
