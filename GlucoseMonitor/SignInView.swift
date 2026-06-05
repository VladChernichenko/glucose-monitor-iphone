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
    @State private var username = ""
    @State private var password = ""
    @State private var status = ""
    @State private var isBusy = false

    var body: some View {
        VStack(spacing: 16) {
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
            username = GlucoseMonitorAPI.storedAppUsername()
            password = GlucoseMonitorAPI.storedAppPassword()
        }
    }

    private func signIn() async {
        isBusy = true
        status = ""
        defer { isBusy = false }
        do {
            let base = GlucoseMonitorAPI.effectiveBackendBaseURL()
            try await GlucoseMonitorAPI.loginAppAccount(username: username, password: password, baseURL: base)
            GlucoseMonitorAPI.saveAppLoginCredentials(username: username, password: password)
            await MainActor.run { appState.checkAuthentication() }
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }
}

