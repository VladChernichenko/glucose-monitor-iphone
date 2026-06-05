import SwiftUI

struct OnboardingRegisterView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = RegistrationFormViewModel()
    @State private var navigateToDataSource = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 52))
                        .foregroundStyle(.tint)
                    Text("Create Account")
                        .font(.title.bold())
                    Text("Step 1 of 2")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)

                VStack(spacing: 12) {
                    TextField("Full name", text: $vm.fullName)
                        .textContentType(.name)
                        .fieldStyle()
                    TextField("Username", text: $vm.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .fieldStyle()
                    TextField("Email", text: $vm.email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .fieldStyle()
                    SecureField("Password (min 6 chars)", text: $vm.password)
                        .textContentType(.newPassword)
                        .fieldStyle()
                    SecureField("Confirm password", text: $vm.confirmPassword)
                        .textContentType(.newPassword)
                        .fieldStyle()
                }

                if vm.passwordMismatch {
                    Text("Passwords don't match.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if !vm.status.isEmpty {
                    Text(vm.status)
                        .font(.footnote)
                        .foregroundStyle(vm.status.hasPrefix("Error") ? .red : .green)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task {
                        if await vm.register() {
                            navigateToDataSource = true
                        }
                    }
                } label: {
                    Group {
                        if vm.isBusy {
                            ProgressView()
                        } else {
                            Text("Continue")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canSubmit)
            }
            .padding()
        }
        .navigationTitle("Register")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToDataSource) {
            OnboardingDataSourceView()
                .environmentObject(appState)
        }
    }
}

private extension View {
    func fieldStyle() -> some View {
        self
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
