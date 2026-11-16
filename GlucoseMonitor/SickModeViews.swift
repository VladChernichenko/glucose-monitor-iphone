import SwiftUI

/// Wording for the sick-mode views. Pure, so it is unit-tested. Never dosing advice.
enum SickModeText {
    static let ketoneHint = "Check ketones if you can."
    static let helpLine = "Vomiting, fast breathing, or highs that will not come down are reasons to get medical help."
    static let pickerLevels: [SickSeverity] = SickSeverity.allCases.filter(\.selectable)

    static func name(_ s: SickSeverity) -> String {
        switch s {
        case .mild: return "mild"
        case .moderate: return "moderate"
        case .severe: return "severe"
        case .severeUnresponsive: return "severe, not responding"
        }
    }

    /// Fixed per-level ISF change, used where the server status is not at hand (picker, step-up question).
    static func isfPercent(_ s: SickSeverity) -> Int {
        switch s {
        case .mild: return -15
        case .moderate: return -30
        case .severe: return -50
        case .severeUnresponsive: return -60
        }
    }

    private static func basalPercent(_ s: SickSeverity) -> Int {
        switch s {
        case .mild: return 0
        case .moderate: return 15
        case .severe, .severeUnresponsive: return 30
        }
    }

    private static func signed(_ n: Int) -> String {
        n < 0 ? "−\(-n)%" : "+\(n)%"
    }

    /// "Sick · moderate · day 2"
    static func title(_ s: SickModeStatus) -> String {
        var parts = ["Sick"]
        if let sev = s.severity { parts.append(name(sev)) }
        if let day = s.dayNumber { parts.append("day \(day)") }
        return parts.joined(separator: " · ")
    }

    /// "ISF −30% · basal need +15%"
    static func detail(_ s: SickModeStatus) -> String {
        var parts: [String] = []
        if let isf = s.isfPercent { parts.append("ISF \(signed(isf))") }
        if let basal = s.basalNeedPercent { parts.append("basal need \(signed(basal))") }
        return parts.joined(separator: " · ")
    }

    static func symptoms(_ s: SickSeverity) -> String {
        let effect = "(ISF \(signed(isfPercent(s))), basal need \(signed(basalPercent(s))))"
        switch s {
        case .mild: return "Runny nose, mild cold, no fever \(effect)"
        case .moderate: return "Fever 37.5–38.5 °C, body aches \(effect)"
        case .severe: return "Fever above 38.5 °C, infection \(effect)"
        case .severeUnresponsive: return "Severe, not responding \(effect)"
        }
    }

    static func stepUpQuestion(_ to: SickSeverity?) -> String {
        guard let to else { return "" }
        let level = to == .severeUnresponsive ? "severe illness, not responding" : "\(name(to)) illness"
        return "Treat this as \(level)? (ISF \(signed(isfPercent(to))))"
    }

    static func keepTitle(_ current: SickSeverity?) -> String {
        "Keep \(current.map(name) ?? "current")"
    }

    static func sinceTitle(_ s: SickSince) -> String {
        switch s {
        case .now: return "Now"
        case .thisMorning: return "This morning"
        case .yesterday: return "Yesterday"
        }
    }
}

private struct SickCardBackground: ViewModifier {
    let tint: Color
    func body(content: Content) -> some View {
        content
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.4), lineWidth: 1))
    }
}

private extension View {
    func sickCard(_ tint: Color = .orange) -> some View { modifier(SickCardBackground(tint: tint)) }
}

/// Active state: title, detail and [Change] / [End].
struct SickModeCard: View {
    let status: SickModeStatus
    let isBusy: Bool
    let onChange: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SickModeText.title(status)).font(.subheadline.bold())
            let detail = SickModeText.detail(status)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Change", action: onChange).buttonStyle(.bordered)
                Button("End", role: .destructive, action: onEnd).buttonStyle(.bordered)
            }
            .disabled(isBusy)
        }
        .sickCard()
    }
}

/// Off state: a small "I'm sick" row.
struct SickModeEntry: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "thermometer.medium")
                Text("I'm sick").font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// Morning question: [Yes, same] [Change] [No].
struct StillSickPrompt: View {
    let isBusy: Bool
    let onSame: () -> Void
    let onChange: () -> Void
    let onNo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Still sick?").font(.subheadline.bold())
            HStack {
                Button("Yes, same", action: onSame)
                Button("Change", action: onChange)
                Button("No", action: onNo)
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
        .sickCard()
    }
}

/// Step-up proposal after a stubborn high. With no target level it is a hint only, answered with [OK].
struct SickStepUpCard: View {
    let stepUp: SickModeStatus.StepUp
    let currentSeverity: SickSeverity?
    let isBusy: Bool
    let onDecide: (_ accept: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stubborn high").font(.subheadline.bold())
            Text("Glucose is not coming down as expected.").font(.footnote)
            if stepUp.toSeverity != nil {
                Text(SickModeText.stepUpQuestion(stepUp.toSeverity)).font(.footnote)
            }
            Text(SickModeText.ketoneHint).font(.footnote)
            if stepUp.showHelpLine {
                Text(SickModeText.helpLine).font(.footnote).foregroundStyle(.red)
            }
            HStack {
                if stepUp.toSeverity != nil {
                    Button("Yes, raise") { onDecide(true) }
                    Button(SickModeText.keepTitle(currentSeverity)) { onDecide(false) }
                } else {
                    Button("OK") { onDecide(false) }
                }
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
        .sickCard(.red)
    }
}

/// Start ("Since when?" shown) or change (severity only) sheet.
struct SickSeverityPicker: View {
    enum Mode { case start, change }

    let mode: Mode
    let initial: SickSeverity?
    let onConfirm: (_ severity: SickSeverity, _ since: SickSince) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var severity: SickSeverity
    @State private var since: SickSince = .now

    init(mode: Mode, initial: SickSeverity?, onConfirm: @escaping (SickSeverity, SickSince) -> Void) {
        self.mode = mode
        self.initial = initial
        self.onConfirm = onConfirm
        _severity = State(initialValue: initial.flatMap { $0.selectable ? $0 : nil } ?? .mild)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("How sick are you?") {
                    ForEach(SickModeText.pickerLevels, id: \.self) { level in
                        Button {
                            severity = level
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(SickModeText.name(level).capitalized).font(.subheadline.bold())
                                    Text(SickModeText.symptoms(level)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if level == severity { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if mode == .start {
                    Section("Since when?") {
                        Picker("Since when?", selection: $since) {
                            ForEach([SickSince.now, .thisMorning, .yesterday], id: \.self) {
                                Text(SickModeText.sinceTitle($0)).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .navigationTitle(mode == .start ? "Sick mode" : "Change level")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .start ? "Start" : "Save") {
                        onConfirm(severity, since)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// Dashboard glue: picks which card to show and maps buttons to the AppState commands.
struct SickModeSection: View {
    @ObservedObject var appState: AppState
    @State private var pickerMode: SickSeverityPicker.Mode?
    @State private var isBusy = false

    var body: some View {
        content
            .sheet(item: Binding(get: { pickerMode.map(PickerRequest.init) }, set: { pickerMode = $0?.mode })) { request in
                SickSeverityPicker(mode: request.mode, initial: appState.sickMode?.severity) { severity, since in
                    run {
                        if request.mode == .start {
                            await appState.startSickMode(severity, since: since)
                        } else {
                            await appState.changeSickSeverity(severity)
                        }
                    }
                }
            }
    }

    private struct PickerRequest: Identifiable {
        let mode: SickSeverityPicker.Mode
        var id: Int { mode == .start ? 0 : 1 }
    }

    @ViewBuilder private var content: some View {
        let fromCache = appState.calculationsFromCache
        if let status = appState.sickMode, status.active {
            if !fromCache, let stepUp = status.stepUp {
                SickStepUpCard(stepUp: stepUp, currentSeverity: status.severity, isBusy: isBusy) { accept in
                    run { await appState.decideSickStepUp(accept: accept) }
                }
            } else if !fromCache, status.confirmationDue {
                StillSickPrompt(isBusy: isBusy,
                                onSame: { run { await appState.confirmStillSick() } },
                                onChange: { pickerMode = .change },
                                onNo: { run { await appState.endSickMode(reason: "MORNING_NO") } })
            } else {
                SickModeCard(status: status, isBusy: isBusy || fromCache,
                             onChange: { pickerMode = .change },
                             onEnd: { run { await appState.endSickMode(reason: "USER") } })
            }
        } else if !fromCache {
            SickModeEntry { pickerMode = .start }
        }
    }

    private func run(_ command: @escaping () async -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await command()
            isBusy = false
        }
    }
}
