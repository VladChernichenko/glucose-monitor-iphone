import SwiftUI

struct SignInView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.system(size: 52))
                        .foregroundStyle(.tint)
                    Text("Glucose Monitor")
                        .font(.title.bold())
                    Text("Track your glucose, anywhere.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 48)
                .padding(.bottom, 32)

                SignInForm()

                NavigationLink {
                    OnboardingRegisterView()
                        .environmentObject(appState)
                } label: {
                    Text("Don't have an account? **Sign Up**")
                        .font(.subheadline)
                        .padding(.top, 8)
                }

                Spacer()
            }
            .navigationBarHidden(true)
        }
    }
}

// MARK: - Sign In

private struct SignInForm: View {
    @EnvironmentObject var appState: AppState
    #if DEBUG
    @State private var localIP = ""
    @State private var useLocalServer = false
    #endif
    @State private var username = ""
    @State private var password = ""
    @State private var status = ""
    @State private var isBusy = false

    var body: some View {
        VStack(spacing: 16) {
            #if DEBUG
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Use local server (debug)", isOn: $useLocalServer)
                if useLocalServer {
                    HStack {
                        Text("Server IP")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("192.168.1.10", text: $localIP)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: localIP) { newIP in
                                let filtered = newIP.filter { $0.isNumber || $0 == "." }
                                if filtered != newIP { localIP = filtered }
                            }
                    }
                    Button("Apply local server") {
                        GlucoseMonitorAPI.storeLocalIP(localIP)
                        if !localIP.isEmpty {
                            GlucoseMonitorAPI.storeBackendBaseURL(GlucoseMonitorAPI.localBackendURL())
                            status = "Backend set to local server."
                        }
                    }
                    .disabled(localIP.isEmpty)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            #endif

            Group {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if !status.isEmpty {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(status.hasPrefix("Error") ? .red : .green)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await signIn() }
            } label: {
                Group {
                    if isBusy {
                        ProgressView()
                    } else {
                        Text("Sign In")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || username.isEmpty || password.isEmpty)
        }
        .padding()
        .onAppear {
            #if DEBUG
            localIP = GlucoseMonitorAPI.sharedDefaults().string(forKey: GlucoseMonitorAPI.StorageKey.localIP) ?? ""
            useLocalServer = !localIP.isEmpty
            #endif
            username = GlucoseMonitorAPI.storedAppUsername()
            password = GlucoseMonitorAPI.storedAppPassword()
        }
    }

    private func signIn() async {
        isBusy = true
        status = ""
        defer { isBusy = false }
        do {
            #if DEBUG
            let base = useLocalServer && !localIP.isEmpty
                ? GlucoseMonitorAPI.localBackendURL()
                : GlucoseMonitorAPI.effectiveBackendBaseURL()
            #else
            let base = GlucoseMonitorAPI.effectiveBackendBaseURL()
            #endif
            try await GlucoseMonitorAPI.loginAppAccount(username: username, password: password, baseURL: base)
            GlucoseMonitorAPI.saveAppLoginCredentials(username: username, password: password)
            await MainActor.run { appState.checkAuthentication() }
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }
}
