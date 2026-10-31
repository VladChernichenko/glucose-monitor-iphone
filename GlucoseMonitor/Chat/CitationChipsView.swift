import SafariServices
import SwiftUI

/// Tappable source chips under a question reply (spec screen 8): "[1] Title · Source 2024".
/// A tap opens the source in an in-app Safari view.
struct CitationChipsView: View {
    let citations: [BackendAPI.AssistantCitation]
    @State private var opened: BackendAPI.AssistantCitation?

    var body: some View {
        HStack {
            CitationChipsFlow(spacing: 6) {
                ForEach(citations) { citation in
                    Button { opened = citation } label: {
                        Text(citation.chipLabel)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(Color.accentColor)
                            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Source \(citation.ref): \(citation.title)")
                    .accessibilityHint("Opens the source")
                }
            }
            Spacer(minLength: 24)
        }
        .sheet(item: $opened) { citation in
            SafariView(url: citation.url).ignoresSafeArea()
        }
    }
}

/// Wraps chips onto new lines (iOS 16 `Layout`).
private struct CitationChipsFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (origins, CGSize(width: maxX, height: y + rowHeight))
    }
}

/// `SFSafariViewController` for SwiftUI. Callers pass only http(s) URLs (`AssistantCitation` guarantees it).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
