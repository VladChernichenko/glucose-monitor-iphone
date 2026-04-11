import SwiftUI
import UIKit

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
        case .local: return "http://192.168.100.8:8080"
        case .remote: return GlucoseMonitorAPI.defaultBackendBaseURL
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    // Backend
    @State private var backendPreset: BackendPreset = .remote
    @State private var username = ""
    @State private var password = ""
    @State private var signInStatus = ""

    // Data source
    @State private var dataSource = "libre"

    // LibreLinkUp
    @State private var libreEmail = ""
    @State private var librePassword = ""
    @State private var patientId = ""
    @State private var libreStatus = ""

    // Nightscout
    @State private var nightscoutURL = ""
    @State private var nightscoutSecret = ""
    @State private var nightscoutStatus = ""

    // COB Settings
    @State private var cobSettings = BackendAPI.COBSettings(
        carbRatio: 10, isf: 2.5, carbHalfLife: 60, maxCOBDuration: 240
    )
    @State private var cobStatus = ""

    // Insulin Preferences
    @State private var rapidCatalog: [BackendAPI.InsulinCatalogEntry] = []
    @State private var longActingCatalog: [BackendAPI.InsulinCatalogEntry] = []
    @State private var selectedRapid = ""
    @State private var selectedLongActing = ""
    @State private var insulinStatus = ""

    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            Form {
                backendSection
                dataSourceSection
                if dataSource == "libre" { libreSection }
                if dataSource == "nightscout" { nightscoutSection }
                if appState.isAuthenticated {
                    cobSection
                    insulinSection
                    accountSection
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: loadStoredValues)
            .task {
                if appState.isAuthenticated {
                    await loadRemoteSettings()
                }
            }
        }
    }

    // MARK: - Sections

    private var backendSection: some View {
        Section("Backend") {
            Picker("Server", selection: $backendPreset) {
                ForEach(BackendPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: backendPreset) { newValue in
                GlucoseMonitorAPI.storeBackendBaseURL(newValue.url)
            }
            Text(backendPreset.url)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            TextField("Username", text: $username)
                .textContentType(.username)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .onChange(of: username) { _ in persistAppLoginCredentials() }
            SecureField("Password", text: $password)
                .textContentType(.password)
                .onChange(of: password) { _ in persistAppLoginCredentials() }

            Button("Sign In") {
                dismissKeyboard()
                Task { await signIn() }
            }
            .disabled(isBusy || username.isEmpty || password.isEmpty)

            if !signInStatus.isEmpty {
                Text(signInStatus)
                    .font(.footnote)
                    .foregroundColor(signInStatus.hasPrefix("OK") ? .green : .red)
            }
        }
    }

    private var dataSourceSection: some View {
        Section("Data Source") {
            Picker("Source", selection: $dataSource) {
                Text("LibreLinkUp").tag("libre")
                Text("Nightscout").tag("nightscout")
            }
            .pickerStyle(.segmented)
            .onChange(of: dataSource) { newValue in
                GlucoseMonitorAPI.sharedDefaults().set(newValue, forKey: GlucoseMonitorAPI.StorageKey.dataSource)
            }
        }
    }

    private var libreSection: some View {
        Section("LibreLinkUp") {
            TextField("Email", text: $libreEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                .autocorrectionDisabled()
            SecureField("Password", text: $librePassword)
                .textContentType(.password)
            TextField("Patient / Connection ID", text: $patientId)
                .autocapitalization(.none)
                .autocorrectionDisabled()

            Button("Sync LibreLinkUp") {
                Task { await syncLibre() }
            }
            .disabled(isBusy || libreEmail.isEmpty || librePassword.isEmpty || patientId.isEmpty || !appState.isAuthenticated)

            if !libreStatus.isEmpty {
                Text(libreStatus)
                    .font(.footnote)
                    .foregroundColor(libreStatus.hasPrefix("OK") ? .green : .red)
            }
        }
    }

    private var nightscoutSection: some View {
        Section("Nightscout") {
            TextField("Nightscout URL", text: $nightscoutURL)
                .textContentType(.URL)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .autocorrectionDisabled()
            SecureField("API Secret (optional)", text: $nightscoutSecret)

            Button("Save Nightscout Config") {
                Task { await saveNightscout() }
            }
            .disabled(isBusy || nightscoutURL.isEmpty || !appState.isAuthenticated)

            if !nightscoutStatus.isEmpty {
                Text(nightscoutStatus)
                    .font(.footnote)
                    .foregroundColor(nightscoutStatus.hasPrefix("OK") ? .green : .red)
            }
        }
    }

    private var cobSection: some View {
        Section("Carb Absorption (COB)") {
            numericRow(label: "Carb Ratio (g/u)", placeholder: "10", value: $cobSettings.carbRatio)
            numericRow(label: "ISF (mmol/L per u)", placeholder: "2.5", value: $cobSettings.isf)

            Button("Save COB Settings") {
                Task { await saveCOB() }
            }
            .disabled(isBusy)

            if !cobStatus.isEmpty {
                Text(cobStatus)
                    .font(.footnote)
                    .foregroundColor(cobStatus.hasPrefix("OK") ? .green : .red)
            }
        }
    }

    private var insulinSection: some View {
        Section("Insulin Preferences") {
            if rapidCatalog.isEmpty {
                HStack {
                    ProgressView()
                    Text("Loading catalog...")
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
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

                Button("Save Insulin Preferences") {
                    Task { await saveInsulinPrefs() }
                }
                .disabled(isBusy || selectedRapid.isEmpty || selectedLongActing.isEmpty)

                if !insulinStatus.isEmpty {
                    Text(insulinStatus)
                        .font(.footnote)
                        .foregroundColor(insulinStatus.hasPrefix("OK") ? .green : .red)
                }
            }
        }
    }

    private var accountSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                Task { await appState.logout() }
            }
        }
    }

    // MARK: - Actions

    private func loadStoredValues() {
        let ud = GlucoseMonitorAPI.sharedDefaults()
        let storedBackend = ud.string(forKey: GlucoseMonitorAPI.StorageKey.backendURL) ?? ""
        let normStored = storedBackend.isEmpty ? "" : Self.normalizeURLString(storedBackend)
        let nLocal = Self.normalizeURLString(BackendPreset.local.url)
        let nRemote = Self.normalizeURLString(BackendPreset.remote.url)
        if normStored.isEmpty {
            backendPreset = .remote
        } else if normStored == nLocal {
            backendPreset = .local
        } else if normStored == nRemote {
            backendPreset = .remote
        } else {
            backendPreset = .remote
            GlucoseMonitorAPI.storeBackendBaseURL(BackendPreset.remote.url)
        }
        username = GlucoseMonitorAPI.storedAppUsername()
        password = GlucoseMonitorAPI.storedAppPassword()
        libreEmail    = ud.string(forKey: GlucoseMonitorAPI.StorageKey.libreEmail) ?? ""
        librePassword = ud.string(forKey: GlucoseMonitorAPI.StorageKey.librePassword) ?? ""
        patientId     = ud.string(forKey: GlucoseMonitorAPI.StorageKey.patientId) ?? ""
        dataSource    = ud.string(forKey: GlucoseMonitorAPI.StorageKey.dataSource) ?? "libre"
    }

    private func persistAppLoginCredentials() {
        GlucoseMonitorAPI.saveAppLoginCredentials(username: username, password: password)
    }

    private func loadRemoteSettings() async {
        async let cob = loadCOBSettings()
        async let insulin = loadInsulinCatalog()
        async let nightscout = loadNightscoutConfig()
        _ = await (cob, insulin, nightscout)
    }

    private func loadCOBSettings() async {
        if let settings = try? await BackendAPI.fetchCOBSettings() {
            cobSettings = settings
        }
    }

    private func loadInsulinCatalog() async {
        async let rapidFetch = BackendAPI.fetchInsulinCatalog(category: "RAPID")
        async let longFetch  = BackendAPI.fetchInsulinCatalog(category: "LONG_ACTING")
        rapidCatalog     = (try? await rapidFetch) ?? []
        longActingCatalog = (try? await longFetch) ?? []

        if let prefs = try? await BackendAPI.fetchInsulinPreferences() {
            selectedRapid      = prefs.rapidInsulinCode
            selectedLongActing = prefs.longActingInsulinCode
        } else {
            selectedRapid      = rapidCatalog.first?.code ?? ""
            selectedLongActing = longActingCatalog.first?.code ?? ""
        }
    }

    private func loadNightscoutConfig() async {
        do {
            if let config = try await BackendAPI.fetchNightscoutConfig() {
                nightscoutURL    = config.url
                nightscoutSecret = config.secret ?? ""
            }
        } catch {
            // No saved config or network error; keep current field values.
        }
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
            await loadRemoteSettings()
        } catch {
            signInStatus = error.localizedDescription
        }
    }

    private func syncLibre() async {
        isBusy = true
        libreStatus = ""
        defer { isBusy = false }
        do {
            GlucoseMonitorAPI.savePatientId(patientId)
            try await GlucoseMonitorAPI.loginLibre(email: libreEmail, password: librePassword)
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

    private func saveCOB() async {
        isBusy = true
        cobStatus = ""
        defer { isBusy = false }
        do {
            cobSettings = try await BackendAPI.saveCOBSettings(cobSettings)
            cobStatus = "OK: COB settings saved."
        } catch {
            cobStatus = error.localizedDescription
        }
    }

    private func saveInsulinPrefs() async {
        isBusy = true
        insulinStatus = ""
        defer { isBusy = false }
        do {
            _ = try await BackendAPI.saveInsulinPreferences(
                rapidCode: selectedRapid,
                longActingCode: selectedLongActing
            )
            insulinStatus = "OK: insulin preferences saved."
        } catch {
            insulinStatus = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private static func normalizeURLString(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func numericRow(label: String, placeholder: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
        }
    }
}