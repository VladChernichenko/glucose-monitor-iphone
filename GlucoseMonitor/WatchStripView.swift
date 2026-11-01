import SwiftUI

/// The dashboard watch strip: a bold headline over one detail line. Red for urgent states, green for calm.
struct WatchStripView: View {
    let strip: BackendAPI.WatchStrip
    let unit: String
    let onTap: () -> Void

    private var tint: Color { strip.state == .calm ? .green : .red }

    var body: some View {
        let headline = WatchStripText.headline(strip, unit: unit)
        let detail = WatchStripText.detail(strip, unit: unit)
        Button(action: onTap) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.subheadline.bold())
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(tint.opacity(0.4), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(headline). \(detail)")
    }
}
