import SwiftUI

// MARK: - Backend preset

private enum BackendPreset: String, CaseIterable, Identifiable {
    case local
    case remote
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return "Local"
        case .remote: return "Remote"
        }
    }
    var url: String {
        switch self {
        case .local: return GlucoseMonitorAPI.localBackendURL()
        case .remote: return GlucoseMonitorAPI.defaultBackendBaseURL
        }
    }
}

private enum DataSourceKind: String, CaseIterable, Identifiable {
    case libre
    case nightscout
    var id: String { rawValue }
    var title: String {
        switch self {
        case .libre: return "LibreLinkUp"
        case .nightscout: return "Nightscout"
        }
    }
}

// MARK: - Native-style row

private struct SettingsIconRow: View {
    let icon: String
    let color: Color
    let title: String
    var value: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title)
            Spacer(minLength: 8)
            if let value, !value.isEmpty {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Hub

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var backendSummary = "Remote"
    @State private var dataSourceSummary = "LibreLinkUp"
    @State private var glucoseUnit = "mmol/L"
    @State private var insulinSummary = ""
    @State private var cobSettings = BackendAPI.COBSettings(
        carbRatio: 2.0, isf: 2.5, carbHalfLife: 60, maxCOBDuration: 240, bodyWeightKg: nil
    )
    @State private var calculationStatus = ""
    @State private var isSavingCalculations = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        BackendSettingsDetailView(onChange: refreshSummaries)
                    } label: {
                        SettingsIconRow(
                            icon: "server.rack",
                            color: .blue,
                            title: "Backend",
                            value: backendSummary
                        )
                    }
                }

                Section {
                    NavigationLink {
                        DataSourceSettingsDetailView(onChange: refreshSummaries)
                    } label: {
                        SettingsIconRow(
                            icon: "waveform.path.ecg",
                            color: .red,
                            title: "Data Source",
                            value: dataSourceSummary
                        )
                    }
                }

                if appState.isAuthenticated {
                    Section("User Settings") {
                        Picker("Glucose Units", selection: $glucoseUnit) {
                            Text("mmol/L").tag("mmol/L")
                            Text("mg/dL").tag("mg/dL")
                        }
                        .onChange(of: glucoseUnit) { newValue in
                            GlucoseMonitorAPI.sharedDefaults().set(
                                newValue,
                                forKey: GlucoseMonitorAPI.StorageKey.glucoseDisplayUnit
                            )
                            appState.setPreferredGlucoseUnit(newValue)
                        }

                        SettingsNumericRow(
                            label: "Carb Ratio",
                            subtitle: "mmol/L per 10 g",
                            placeholder: "2.0",
                            value: $cobSettings.carbRatio,
                            fractionDigits: 1...2
                        )
                        SettingsNumericRow(
                            label: "ISF Breakfast",
                            subtitle: "mmol/L per unit · 05:00 – 11:00",
                            placeholder: "2.5",
                            value: isfBreakfastBinding,
                            fractionDigits: 1...2
                        )
                        SettingsNumericRow(
                            label: "ISF Lunch",
                            subtitle: "mmol/L per unit · 11:00 – 16:00",
                            placeholder: "2.5",
                            value: isfLunchBinding,
                            fractionDigits: 1...2
                        )
                        SettingsNumericRow(
                            label: "ISF Dinner",
                            subtitle: "mmol/L per unit · 16:00 – 22:00",
                            placeholder: "2.5",
                            value: isfDinnerBinding,
                            fractionDigits: 1...2
                        )
                        SettingsNumericRow(
                            label: "Body Weight",
                            subtitle: "kg · used for glucose model calibration",
                            placeholder: "70",
                            value: bodyWeightBinding,
                            fractionDigits: 0...1
                        )

                        Button("Save") {
                            Task { await saveCalculationSettings() }
                        }
                        .disabled(isSavingCalculations)

                        if !calculationStatus.isEmpty {
                            Text(calculationStatus)
                                .font(.footnote)
                                .foregroundStyle(calculationStatus.hasPrefix("OK") ? .green : .red)
                        }

                        NavigationLink {
                            InsulinPreferencesDetailView(onChange: refreshSummaries)
                        } label: {
                            SettingsIconRow(
                                icon: "syringe.fill",
                                color: .orange,
                                title: "Insulin Preferences",
                                value: insulinSummary
                            )
                        }

                        Button("Sign Out", role: .destructive) {
                            Task { await appState.logout() }
                        }
                    }
                }
            }
            .dismissKeyboardOnInteraction()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .onAppear(perform: refreshSummaries)
            .task(id: appState.isAuthenticated) {
                if appState.isAuthenticated {
                    await loadCalculationSettings()
                }
            }
        }
    }

    /// Bridges the optional `bodyWeightKg` to the non-optional `Double` expected by `SettingsNumericRow`.
    /// Reading: returns stored weight or 70 (population default). Writing: stores the value, clears if ≤ 0.
    private var bodyWeightBinding: Binding<Double> {
        Binding(
            get: { cobSettings.bodyWeightKg ?? 70.0 },
            set: { cobSettings.bodyWeightKg = $0 > 0 ? $0 : nil }
        )
    }

    /// Per-meal-window ISF overrides default to the autotuned `isf` until the user edits them;
    /// any edit pins a manual override for that window (saved on "Save").
    private var isfBreakfastBinding: Binding<Double> {
        Binding(
            get: { cobSettings.isfBreakfast ?? cobSettings.isf },
            set: { cobSettings.isfBreakfast = $0 }
        )
    }

    private var isfLunchBinding: Binding<Double> {
        Binding(
            get: { cobSettings.isfLunch ?? cobSettings.isf },
            set: { cobSettings.isfLunch = $0 }
        )
    }

    private var isfDinnerBinding: Binding<Double> {
        Binding(
            get: { cobSettings.isfDinner ?? cobSettings.isf },
            set: { cobSettings.isfDinner = $0 }
        )
    }

    private func loadCalculationSettings() async {
        if let settings = try? await BackendAPI.fetchCOBSettings() {
            cobSettings = settings
        }
    }

    private func saveCalculationSettings() async {
        isSavingCalculations = true
        calculationStatus = ""
        defer { isSavingCalculations = false }
        do {
            cobSettings = try await BackendAPI.saveCOBSettings(cobSettings)
            calculationStatus = "OK: settings saved."
        } catch {
            calculationStatus = error.localizedDescription
        }
    }

    private func refreshSummaries() {
        let ud = GlucoseMonitorAPI.sharedDefaults()
        localIPSummary(ud: ud)
        dataSourceSummary = DataSourceKind(rawValue: appState.dataSource)?.title ?? "LibreLinkUp"
        glucoseUnit = ud.string(forKey: GlucoseMonitorAPI.StorageKey.glucoseDisplayUnit) ?? "mmol/L"
        insulinSummary = appState.insulinPrefs?.rapidInsulin.displayName ?? ""
    }

    private func localIPSummary(ud: UserDefaults) {
        let localIP = ud.string(forKey: GlucoseMonitorAPI.StorageKey.localIP) ?? ""
        let storedBackend = ud.string(forKey: GlucoseMonitorAPI.StorageKey.backendURL) ?? ""
        let normStored = storedBackend.isEmpty ? "" : SettingsHelpers.normalizeURLString(storedBackend)
        let nLocal = SettingsHelpers.normalizeURLString(GlucoseMonitorAPI.localBackendURL())
        let nRemote = SettingsHelpers.normalizeURLString(BackendPreset.remote.url)
        if normStored == nLocal && !localIP.isEmpty {
            backendSummary = "Local"
        } else if normStored == nRemote || normStored.isEmpty {
            backendSummary = "Remote"
        } else {
            backendSummary = "Remote"
        }
    }
}

// MARK: - Backend detail

private struct BackendSettingsDetailView: View {
    @EnvironmentObject var appState: AppState
    var onChange: () -> Void = {}

    @State private var backendPreset: BackendPreset = .remote
    @State private var localIP = ""
    @State private var username = ""
    @State private var password = ""
    @State private var signInStatus = ""
    @State private var isBusy = false

    var body: some View {
        Form {
            Section {
                Picker("Server", selection: $backendPreset) {
                    ForEach(BackendPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .onChange(of: backendPreset) { newValue in
                    GlucoseMonitorAPI.storeBackendBaseURL(newValue.url)
                    onChange()
                }

                if backendPreset == .local {
                    HStack {
                        Text("IP Address")
                        Spacer()
                        TextField("192.168.1.10", text: $localIP)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: localIP) { newIP in
                                let filtered = newIP.filter { $0.isNumber || $0 == "." }
                                if filtered != newIP { localIP = filtered; return }
                                GlucoseMonitorAPI.storeLocalIP(filtered)
                                GlucoseMonitorAPI.storeBackendBaseURL(GlucoseMonitorAPI.localBackendURL())
                                onChange()
                            }
                    }
                }

                LabeledContent("URL") {
                    Text(backendPreset.url)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Account") {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: username) { _ in persistAppLoginCredentials() }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .onChange(of: password) { _ in persistAppLoginCredentials() }

                Button("Sign In") {
                    hideKeyboard()
                    Task { await signIn() }
                }
                .disabled(isBusy || username.isEmpty || password.isEmpty)

                if !signInStatus.isEmpty {
                    Text(signInStatus)
                        .font(.footnote)
                        .foregroundStyle(signInStatus.hasPrefix("OK") ? .green : .red)
                }
            }
        }
        .dismissKeyboardOnInteraction()
        .navigationTitle("Backend")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadStoredValues)
    }

    private func loadStoredValues() {
        let ud = GlucoseMonitorAPI.sharedDefaults()
        localIP = ud.string(forKey: GlucoseMonitorAPI.StorageKey.localIP) ?? ""
        let storedBackend = ud.string(forKey: GlucoseMonitorAPI.StorageKey.backendURL) ?? ""
        let normStored = storedBackend.isEmpty ? "" : SettingsHelpers.normalizeURLString(storedBackend)
        let nLocal = SettingsHelpers.normalizeURLString(GlucoseMonitorAPI.localBackendURL())
        let nRemote = SettingsHelpers.normalizeURLString(BackendPreset.remote.url)
        if normStored.isEmpty {
            backendPreset = .remote
        } else if normStored == nLocal && !localIP.isEmpty {
            backendPreset = .local
        } else if normStored == nRemote {
            backendPreset = .remote
        } else {
            backendPreset = .remote
            GlucoseMonitorAPI.storeBackendBaseURL(BackendPreset.remote.url)
        }
        username = GlucoseMonitorAPI.storedAppUsername()
        password = GlucoseMonitorAPI.storedAppPassword()
    }

    private func persistAppLoginCredentials() {
        GlucoseMonitorAPI.saveAppLoginCredentials(username: username, password: password)
    }

    private func signIn() async {
        isBusy = true
        signInStatus = ""
        defer { isBusy = false }
        do {
            try await GlucoseMonitorAPI.loginAppAccount(
                username: username,
                password: password,
                baseURL: backendPreset.url
            )
            appState.checkAuthentication()
            persistAppLoginCredentials()
            signInStatus = "OK: signed in."
            onChange()
        } catch {
            signInStatus = error.localizedDescription
        }
    }
}

// MARK: - Data source detail

private struct DataSourceSettingsDetailView: View {
    @EnvironmentObject var appState: AppState
    var onChange: () -> Void = {}

    @State private var dataSource: DataSourceKind = .libre
    @State private var libreEmail = ""
    @State private var librePassword = ""
    @State private var libreRegion = "en-EU"
    @State private var libreStatus = ""
    @State private var nightscoutURL = ""
    @State private var nightscoutSecret = ""
    @State private var nightscoutStatus = ""
    @State private var isBusy = false

    private static let libreRegions: [(label: String, locale: String)] = [
        ("Europe", "en-EU"),
        ("France", "fr-FR"),
        ("Germany", "de-DE"),
        ("United Kingdom", "en-GB"),
        ("United States", "en-US"),
        ("Australia", "en-AU"),
        ("Japan", "ja-JP"),
        ("UAE", "ar-AE"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Source", selection: $dataSource) {
                    ForEach(DataSourceKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .onChange(of: dataSource) { newValue in
                    appState.dataSource = newValue.rawValue
                    GlucoseMonitorAPI.sharedDefaults().set(
                        newValue.rawValue,
                        forKey: GlucoseMonitorAPI.StorageKey.dataSource
                    )
                    onChange()
                }
            }

            if dataSource == .libre {
                Section("LibreLinkUp") {
                    TextField("Email", text: $libreEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $librePassword)
                        .textContentType(.password)
                    Picker("Region", selection: $libreRegion) {
                        ForEach(Self.libreRegions, id: \.locale) { region in
                            Text(region.label).tag(region.locale)
                        }
                    }
                    .onChange(of: libreRegion) { newValue in
                        GlucoseMonitorAPI.sharedDefaults().set(
                            newValue,
                            forKey: GlucoseMonitorAPI.StorageKey.libreRegion
                        )
                    }

                    Button("Sync LibreLinkUp") {
                        Task { await syncLibre() }
                    }
                    .disabled(isBusy || libreEmail.isEmpty || librePassword.isEmpty || !appState.isAuthenticated)

                    if !libreStatus.isEmpty {
                        Text(libreStatus)
                            .font(.footnote)
                            .foregroundStyle(libreStatus.hasPrefix("OK") ? .green : .red)
                    }
                }
            }

            if dataSource == .nightscout {
                Section("Nightscout") {
                    TextField("URL", text: $nightscoutURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Secret (optional)", text: $nightscoutSecret)

                    Button("Save") {
                        Task { await saveNightscout() }
                    }
                    .disabled(isBusy || nightscoutURL.isEmpty || !appState.isAuthenticated)

                    if !nightscoutStatus.isEmpty {
                        Text(nightscoutStatus)
                            .font(.footnote)
                            .foregroundStyle(nightscoutStatus.hasPrefix("OK") ? .green : .red)
                    }
                }
            }
        }
        .dismissKeyboardOnInteraction()
        .navigationTitle("Data Source")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadStoredValues)
        .task {
            if appState.isAuthenticated {
                await loadNightscoutConfig()
            }
        }
    }

    private func loadStoredValues() {
        let ud = GlucoseMonitorAPI.sharedDefaults()
        dataSource = DataSourceKind(rawValue: appState.dataSource) ?? .libre
        libreEmail = ud.string(forKey: GlucoseMonitorAPI.StorageKey.libreEmail) ?? ""
        librePassword = GlucoseMonitorAPI.storedLibrePassword()
        libreRegion = ud.string(forKey: GlucoseMonitorAPI.StorageKey.libreRegion) ?? "en-EU"
    }

    private func loadNightscoutConfig() async {
        if let config = try? await BackendAPI.fetchNightscoutConfig() {
            nightscoutURL = config.url
            nightscoutSecret = config.secret ?? ""
        }
    }

    private func syncLibre() async {
        isBusy = true
        libreStatus = ""
        defer { isBusy = false }
        do {
            try await GlucoseMonitorAPI.loginLibre(
                email: libreEmail,
                password: librePassword,
                regionLocale: libreRegion
            )
            libreStatus = "OK: LibreLinkUp synced."
        } catch {
            libreStatus = error.localizedDescription
        }
    }

    private func saveNightscout() async {
        isBusy = true
        nightscoutStatus = ""
        defer { isBusy = false }
        do {
            try await BackendAPI.saveNightscoutConfig(BackendAPI.NightscoutConfig(
                url: nightscoutURL,
                secret: nightscoutSecret.isEmpty ? nil : nightscoutSecret,
                token: nil
            ))
            nightscoutStatus = "OK: Nightscout config saved."
        } catch {
            nightscoutStatus = error.localizedDescription
        }
    }
}

// MARK: - Insulin preferences detail

private struct InsulinPreferencesDetailView: View {
    @EnvironmentObject var appState: AppState
    var onChange: () -> Void = {}

    @State private var rapidCatalog: [BackendAPI.InsulinCatalogEntry] = []
    @State private var longActingCatalog: [BackendAPI.InsulinCatalogEntry] = []
    @State private var selectedRapid = ""
    @State private var selectedLongActing = ""
    @State private var injectionTimeEnabled = false
    @State private var injectionTime = Date()
    @State private var insulinStatus = ""
    @State private var isBusy = false

    var body: some View {
        Form {
            Section {
                if rapidCatalog.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Rapid Insulin", selection: $selectedRapid) {
                        ForEach(rapidCatalog) { entry in
                            Text(entry.displayName).tag(entry.code)
                        }
                    }
                    Picker("Long-Acting Insulin", selection: $selectedLongActing) {
                        ForEach(longActingCatalog) { entry in
                            Text(entry.displayName).tag(entry.code)
                        }
                    }
                }
            }

            Section {
                Toggle("Daily Injection Time", isOn: $injectionTimeEnabled)
                if injectionTimeEnabled {
                    DatePicker(
                        "Time",
                        selection: $injectionTime,
                        displayedComponents: [.hourAndMinute]
                    )
                }
            } footer: {
                Text("Used for long-acting insulin reminders and IOB calculations.")
                    .font(.footnote)
            }

            Section {
                Button("Save") {
                    Task { await saveInsulinPrefs() }
                }
                .disabled(isBusy || selectedRapid.isEmpty || selectedLongActing.isEmpty)

                if !insulinStatus.isEmpty {
                    Text(insulinStatus)
                        .font(.footnote)
                        .foregroundStyle(insulinStatus.hasPrefix("OK") ? .green : .red)
                }
            }
        }
        .navigationTitle("Insulin Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadInsulinCatalog() }
    }

    private func loadInsulinCatalog() async {
        async let rapidFetch = BackendAPI.fetchInsulinCatalog(category: "RAPID")
        async let longFetch = BackendAPI.fetchInsulinCatalog(category: "LONG_ACTING")
        rapidCatalog = (try? await rapidFetch) ?? []
        longActingCatalog = (try? await longFetch) ?? []

        if let prefs = try? await BackendAPI.fetchInsulinPreferences() {
            selectedRapid = prefs.rapidInsulinCode
            selectedLongActing = prefs.longActingInsulinCode
            if let hhmm = prefs.longActingInjectionTime, let parsed = SettingsHelpers.parseHHmm(hhmm) {
                injectionTimeEnabled = true
                injectionTime = parsed
            } else {
                injectionTimeEnabled = false
            }
            appState.insulinPrefs = prefs
            onChange()
        } else {
            selectedRapid = rapidCatalog.first?.code ?? ""
            selectedLongActing = longActingCatalog.first?.code ?? ""
        }
    }

    private func saveInsulinPrefs() async {
        isBusy = true
        insulinStatus = ""
        defer { isBusy = false }
        do {
            let prefs = try await BackendAPI.saveInsulinPreferences(
                rapidCode: selectedRapid,
                longActingCode: selectedLongActing,
                longActingInjectionTime: injectionTimeEnabled
                    ? SettingsHelpers.formatHHmm(injectionTime) : ""
            )
            appState.insulinPrefs = prefs
            insulinStatus = "OK: insulin preferences saved."
            onChange()
        } catch {
            insulinStatus = error.localizedDescription
        }
    }
}

// MARK: - Numeric row

private struct SettingsNumericRow: View {
    let label: String
    var subtitle: String?
    let placeholder: String
    @Binding var value: Double
    var fractionDigits: ClosedRange<Int> = 0...2

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            TextField(
                placeholder,
                value: $value,
                format: .number.precision(.fractionLength(fractionDigits))
            )
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 72)
        }
    }
}

// MARK: - Helpers

private enum SettingsHelpers {
    static func normalizeURLString(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func parseHHmm(_ hhmm: String) -> Date? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date())
    }

    static func formatHHmm(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
