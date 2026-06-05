import Foundation

// MARK: - Registration

@MainActor
final class RegistrationFormViewModel: ObservableObject {
    @Published var fullName = ""
    @Published var username = ""
    @Published var email = ""
    @Published var password = ""
    @Published var confirmPassword = ""
    @Published var status = ""
    @Published var isBusy = false

    var passwordMismatch: Bool {
        !confirmPassword.isEmpty && password != confirmPassword
    }

    var isEmailValid: Bool {
        let parts = email.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".")
    }

    var canSubmit: Bool {
        !isBusy
            && !fullName.isEmpty
            && !username.isEmpty
            && isEmailValid
            && password.count >= 6
            && password == confirmPassword
    }

    func register() async -> Bool {
        isBusy = true
        status = ""
        defer { isBusy = false }
        do {
            let base = GlucoseMonitorAPI.effectiveBackendBaseURL()
            try await GlucoseMonitorAPI.registerAppAccount(
                username: username, email: email, fullName: fullName,
                password: password, baseURL: base
            )
            GlucoseMonitorAPI.saveAppLoginCredentials(username: username, password: password)
            return true
        } catch {
            status = "Error: \(error.localizedDescription)"
            return false
        }
    }
}

// MARK: - Data source setup

@MainActor
final class DataSourceSetupViewModel: ObservableObject {

    enum Source: String, CaseIterable, Identifiable {
        case libre      = "libre"
        case nightscout = "nightscout"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .libre:      return "LibreLinkUp"
            case .nightscout: return "Nightscout"
            }
        }
    }

    static let libreRegions: [(label: String, locale: String)] = [
        ("🇪🇺 Europe",         "en-EU"),
        ("🇫🇷 France",         "fr-FR"),
        ("🇩🇪 Germany",        "de-DE"),
        ("🇬🇧 United Kingdom", "en-GB"),
        ("🇺🇸 United States",  "en-US"),
        ("🇦🇺 Australia",      "en-AU"),
        ("🇯🇵 Japan",          "ja-JP"),
        ("🇦🇪 UAE",            "ar-AE"),
    ]

    @Published var selectedSource: Source = .libre

    // LibreLinkUp
    @Published var libreEmail = ""
    @Published var librePassword = ""
    @Published var libreRegion = "en-EU"

    // Nightscout
    @Published var nightscoutURL = ""
    @Published var nightscoutSecret = ""

    @Published var status = ""
    @Published var isBusy = false

    var isNightscoutURLValid: Bool {
        !nightscoutURL.isEmpty
            && (nightscoutURL.hasPrefix("http://") || nightscoutURL.hasPrefix("https://"))
    }

    var canContinue: Bool {
        switch selectedSource {
        case .libre:      return !libreEmail.isEmpty && !librePassword.isEmpty
        case .nightscout: return isNightscoutURLValid
        }
    }

    func save(appState: AppState) async -> Bool {
        isBusy = true
        status = ""
        defer { isBusy = false }
        do {
            switch selectedSource {
            case .libre:
                try await GlucoseMonitorAPI.loginLibre(
                    email: libreEmail,
                    password: librePassword,
                    regionLocale: libreRegion
                )
                appState.setDataSource("libre")
            case .nightscout:
                try await BackendAPI.saveNightscoutConfig(BackendAPI.NightscoutConfig(
                    url: nightscoutURL,
                    secret: nightscoutSecret.isEmpty ? nil : nightscoutSecret,
                    token: nil
                ))
                appState.setDataSource("nightscout")
            }
            return true
        } catch {
            status = "Error: \(error.localizedDescription)"
            return false
        }
    }
}
