import SwiftUI

struct SignInView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0

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

                Picker("Mode", selection: $selectedTab) {
                    Text("Sign In").tag(0)
                    Text("Sign Up").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if selectedTab == 0 {
                    SignInForm()
                        .transition(.opacity)
                } else {
                    SignUpForm()
                        .transition(.opacity)
                }

                Spacer()
            }
            .animation(.easeInOut(duration: 0.2), value: selectedTab)
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

// MARK: - Sign Up

private struct SignUpForm: View {
    @EnvironmentObject var appState: AppState
    @State private var username = ""
    @State private var email = ""
    @State private var fullName = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var status = ""
    @State private var isBusy = false

    private var passwordMismatch: Bool { !confirmPassword.isEmpty && password != confirmPassword }
    private var canSubmit: Bool {
        !isBusy && !username.isEmpty && !email.isEmpty && !fullName.isEmpty &&
        password.count >= 6 && password == confirmPassword
    }

    var body: some View {
        VStack(spacing: 16) {
            Group {
                TextField("Full name", text: $fullName)
                    .textContentType(.name)
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                SecureField("Password (min 6 chars)", text: $password)
                    .textContentType(.newPassword)
                SecureField("Confirm password", text: $confirmPassword)
                    .textContentType(.newPassword)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if passwordMismatch {
                Text("Passwords don't match.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if !status.isEmpty {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(status.hasPrefix("Error") ? .red : .green)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await signUp() }
            } label: {
                Group {
                    if isBusy {
                        ProgressView()
                    } else {
                        Text("Create Account")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
        }
        .padding()
    }

    private func signUp() async {
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
            await MainActor.run { appState.checkAuthentication() }
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }
}
