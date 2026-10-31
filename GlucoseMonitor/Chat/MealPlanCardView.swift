import Charts
import SwiftUI

/// What a plan card can do; wired to `ChatViewModel` by the overlay.
struct MealPlanActions {
    let isBusy: Bool
    let onTook: (_ doseUnits: Double, _ pauseMinutes: Int) -> Void
    let onEat: (BackendAPI.MealMacros?) -> Void
    let onSkip: () -> Void
    let onReplan: ([BackendAPI.MealPlanItem]) -> Void
}

/// Meal prep plan card (spec screens 3, 4, 11): macros with ranges, dose, pause, forecast with cone,
/// pattern label and Took it / Edit / Not eating; after Took a countdown to Eating now, amber when the
/// meal was never logged. Re-evaluated every second, so expiry, countdown and amber need no re-render.
struct MealPlanCardView: View {
    let card: MealPlanCard
    let unit: String
    let actions: MealPlanActions

    @State private var showReplan = false
    @State private var showMealEdit = false
    @State private var showDoseEntry = false
    @State private var doseText = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .sheet(isPresented: $showReplan) {
            MealReplanSheet(initial: replanSeed) { actions.onReplan($0) }
        }
        .sheet(isPresented: $showMealEdit) {
            MealMacrosSheet(initial: card.payload.meal ?? midMacros) { actions.onEat($0) }
        }
    }

    private var plan: BackendAPI.MealPlan { card.plan }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let p = card.payload
        let amber = MealPlanRules.isOverdue(p, now: now)
        VStack(alignment: .leading, spacing: 10) {
            switch p.phase {
            case .took: tookSection(now: now, overdue: amber)
            case .eaten: eatenSection
            case .skipped: skippedSection
            default: plannedSection(now: now)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((amber ? Color.orange : Color(.secondarySystemBackground)).opacity(amber ? 0.14 : 1),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(amber ? Color.orange.opacity(0.6) : Color.clear, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
    }

    // MARK: Planned

    @ViewBuilder
    private func plannedSection(now: Date) -> some View {
        let dose = MealPlanRules.advisedDose(card, now: now)
        let expired = MealPlanRules.isExpired(card, now: now)
        HStack {
            if let label = plan.patternLabel {
                Text(label).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.blue.opacity(0.12), in: Capsule())
            }
            Spacer()
        }
        macroGrid
        if let dose {
            HStack(alignment: .firstTextBaseline) {
                Text(MealPlanRules.doseText(dose)).font(.title2.weight(.bold)).monospacedDigit()
                Spacer()
                if let pause = MealPlanRules.advisedPause(card, now: now) {
                    Text(pause == 0 ? "no wait" : "wait \(pause) min").font(.title3.weight(.semibold))
                }
            }
            if let pause = plan.pause {
                forecastChart(pause.curve)
                if let line = MealPlanRules.peakLine(pause, unit: unit) {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                // The backend's reason quotes mmol/L numbers; mg/dL users get the converted line above only.
                if !GlucoseUnit.isMgdl(unit), let reason = pause.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if let why = MealPlanRules.noDoseExplanation(card, now: now) {
            Text(why)
                .font(.subheadline)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.5), lineWidth: 1))
        }
        HStack(spacing: 8) {
            if MealPlanRules.canTakeAdvised(card, now: now), let dose {
                Button("Took it") { actions.onTook(dose, MealPlanRules.advisedPause(card, now: now) ?? 0) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Log a dose\u{2026}") { showDoseEntry.toggle() }
                    .buttonStyle(.bordered)
            }
            Button(expired ? "Re-plan" : "Edit") { showReplan = true }
                .buttonStyle(.bordered)
            Button("Not eating", action: actions.onSkip)
                .buttonStyle(.bordered)
        }
        .disabled(actions.isBusy)
        if showDoseEntry && !MealPlanRules.canTakeAdvised(card, now: now) {
            doseEntryRow
        }
    }

    /// Logging only: the user types the dose they took; nothing is prefilled and no pause is sent.
    private var doseEntryRow: some View {
        HStack(spacing: 8) {
            TextField("units", text: $doseText)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 90)
            Text("U")
            Button("Log") {
                guard let units = enteredDose else { return }
                actions.onTook(units, 0)
                doseText = ""
                showDoseEntry = false
            }
            .buttonStyle(.borderedProminent)
            .disabled(enteredDose == nil || actions.isBusy)
        }
    }

    private var enteredDose: Double? {
        guard let v = Double(doseText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)),
              v > 0, v <= 100 else { return nil }
        return (v * 10).rounded() / 10
    }

    private var macroGrid: some View {
        HStack(alignment: .top, spacing: 0) {
            macroCell("carbs", plan.carbs)
            macroCell("fat", plan.fat)
            macroCell("protein", plan.protein)
            macroCell("fiber", plan.fiber)
        }
    }

    private func macroCell(_ name: String, _ r: BackendAPI.NutritionRange) -> some View {
        VStack(spacing: 2) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(MealPlanRules.midText(r)).font(.headline).monospacedDigit()
            if let range = MealPlanRules.rangeText(r) {
                Text(range).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Took / Eaten / Skipped

    @ViewBuilder
    private func tookSection(now: Date, overdue: Bool) -> some View {
        let p = card.payload
        HStack(alignment: .firstTextBaseline) {
            Text(MealPlanRules.dosedLabel(p)).font(.subheadline.weight(.semibold))
            Spacer()
            if let d = p.description { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        if overdue {
            Text("Meal not logged \u{00B7} \(p.doseUnits.map(MealPlanRules.doseText) ?? "the dose") is active. If you ate, log the meal; if not, eat something or tell me.")
                .font(.subheadline)
            HStack(spacing: 8) {
                Button("I ate") { actions.onEat(nil) }.buttonStyle(.borderedProminent).tint(.orange)
                Button("Edit meal") { showMealEdit = true }.buttonStyle(.bordered)
                Button("Didn't eat", action: actions.onSkip).buttonStyle(.bordered)
            }
            .disabled(actions.isBusy)
        } else {
            VStack(spacing: 2) {
                if let countdown = MealPlanRules.countdown(p, now: now) {
                    Text(countdown).font(.system(size: 28, weight: .bold)).monospacedDigit()
                    Text("until you eat").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Time to eat").font(.title3.weight(.bold))
                }
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Button("Eating now") { actions.onEat(nil) }.buttonStyle(.borderedProminent)
                Button("Edit meal") { showMealEdit = true }.buttonStyle(.bordered)
                Button("Not eating", action: actions.onSkip).buttonStyle(.bordered)
            }
            .disabled(actions.isBusy)
        }
    }

    private var eatenSection: some View {
        let p = card.payload
        let m = p.eatenMeal ?? p.meal
        var text = "Meal \(fmt(m?.carbs)) g"
        if let m { text += " (fat \(fmt(m.fat)), protein \(fmt(m.protein)), fiber \(fmt(m.fiber)))" }
        if let at = p.eatenAt { text += " at \(ChatFormatting.clock(at))" }
        if let dose = p.doseUnits { text += " \u{00B7} \(MealPlanRules.doseText(dose))" }
        return Label(text, systemImage: "checkmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(.primary)
    }

    private var skippedSection: some View {
        let dosed = card.payload.tookAt != nil
        return Label(dosed ? "Not eating \u{2014} the dose stays logged" : "Not eating \u{2014} nothing logged",
                     systemImage: "xmark.circle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func fmt(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "--" }

    // MARK: Forecast

    private struct Sample: Identifiable { let id: Int; let time: Date; let value: Double; let lower: Double?; let upper: Double? }

    @ViewBuilder
    private func forecastChart(_ curve: [BackendAPI.PredictionPathPoint]) -> some View {
        let samples = curve.enumerated().compactMap { i, p -> Sample? in
            guard let g = p.predictedGlucose else { return nil }
            return Sample(id: i, time: p.timestamp, value: GlucoseUnit.fromMmol(g, displayUnit: unit),
                          lower: p.predictedGlucoseLower.map { GlucoseUnit.fromMmol($0, displayUnit: unit) },
                          upper: p.predictedGlucoseUpper.map { GlucoseUnit.fromMmol($0, displayUnit: unit) })
        }
        if samples.count >= 2 {
            let lo = GlucoseUnit.fromMmol(3.9, displayUnit: unit), hi = GlucoseUnit.fromMmol(10, displayUnit: unit)
            Chart {
                RectangleMark(yStart: .value("Low", lo), yEnd: .value("High", hi))
                    .foregroundStyle(Color.green.opacity(0.10))
                ForEach(samples.filter { $0.lower != nil && $0.upper != nil }) { s in
                    AreaMark(x: .value("Time", s.time), yStart: .value("Lower", s.lower!), yEnd: .value("Upper", s.upper!))
                        .foregroundStyle(Color.blue.opacity(0.15))
                }
                ForEach(samples) { s in
                    LineMark(x: .value("Time", s.time), y: .value("Glucose", s.value))
                        .foregroundStyle(Color.blue)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 100)
            .accessibilityLabel("Forecast after this dose and pause")
        }
    }

    // MARK: Edit seeds

    private var midMacros: BackendAPI.MealMacros {
        .init(carbs: plan.carbs.mid, fat: plan.fat.mid, protein: plan.protein.mid, fiber: plan.fiber.mid, gi: plan.gi)
    }

    private var replanSeed: [BackendAPI.MealPlanItem] {
        if let items = card.payload.items, !items.isEmpty { return items }
        return [.init(name: card.payload.description ?? "", grams: nil)]
    }
}

// MARK: - Edit: re-plan with edited items

/// Edit on a PLANNED card: change items and grams, then ask for a fresh plan through the chat.
struct MealReplanSheet: View {
    let initial: [BackendAPI.MealPlanItem]
    let onReplan: ([BackendAPI.MealPlanItem]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []

    struct Row: Identifiable { let id = UUID(); var name: String; var grams: String }

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("Sends a new \u{201C}prepare me for\u{201D} message; you get a fresh plan.")) {
                    ForEach($rows) { $row in
                        HStack {
                            TextField("food", text: $row.name)
                            TextField("g", text: $row.grams)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                            Text("g").foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { rows.remove(atOffsets: $0) }
                    Button("Add item") { rows.append(Row(name: "", grams: "")) }
                }
            }
            .navigationTitle("Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Re-plan") { onReplan(items); dismiss() }.disabled(items.isEmpty)
                }
            }
            .onAppear {
                if rows.isEmpty {
                    rows = initial.map { Row(name: $0.name, grams: $0.grams.map { ChatFormatting.backendNumber($0) } ?? "") }
                }
            }
        }
    }

    private var items: [BackendAPI.MealPlanItem] {
        rows.compactMap { row in
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let grams = Double(row.grams.replacingOccurrences(of: ",", with: "."))
            return .init(name: name, grams: grams.flatMap { (0.1...2000).contains($0) ? $0 : nil })
        }
    }
}

// MARK: - Edit meal: macros for Eating now

/// Edit meal on a TOOK card: adjust macros, then log the meal now.
struct MealMacrosSheet: View {
    let initial: BackendAPI.MealMacros
    let onEat: (BackendAPI.MealMacros) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var carbs = ""
    @State private var fat = ""
    @State private var protein = ""
    @State private var fiber = ""

    var body: some View {
        NavigationStack {
            Form {
                field("Carbs", $carbs)
                field("Fat", $fat)
                field("Protein", $protein)
                field("Fiber", $fiber)
            }
            .navigationTitle("Edit meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Eating now") {
                        if let m = macros { onEat(m); dismiss() }
                    }
                    .disabled(macros == nil)
                }
            }
            .onAppear {
                carbs = text(initial.carbs); fat = text(initial.fat)
                protein = text(initial.protein); fiber = text(initial.fiber)
            }
        }
    }

    private func field(_ title: String, _ value: Binding<String>) -> some View {
        HStack {
            Text(title)
            TextField("0", text: value).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            Text("g").foregroundStyle(.secondary)
        }
    }

    private func text(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "" }

    private func parse(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? 0 : Double(t.replacingOccurrences(of: ",", with: "."))
    }

    /// Nil when out of the backend's limits (carbs/fat/protein 0-300, fiber 0-100, some macros > 0).
    private var macros: BackendAPI.MealMacros? {
        guard let c = parse(carbs), let f = parse(fat), let p = parse(protein), let fi = parse(fiber),
              (0...300).contains(c), (0...300).contains(f), (0...300).contains(p), (0...100).contains(fi),
              c + f + p > 0 else { return nil }
        return .init(carbs: c, fat: f, protein: p, fiber: fi, gi: initial.gi)
    }
}
