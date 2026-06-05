import SwiftUI

struct OnboardingDataSourceView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = DataSourceSetupViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "sensor.tag.radiowaves.forward")
                        .font(.system(size: 52))
                        .foregroundStyle(.tint)
                    Text("Connect Data Source")
                        .font(.title.bold())
                    Text("Step 2 of 2")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)

                Picker("Data source", selection: $vm.selectedSource) {
                    ForEach(DataSourceSetupViewModel.Source.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if vm.selectedSource == .libre {
                    libreForm
                } else {
                    nightscoutForm
                }

                if !vm.status.isEmpty {
                    Text(vm.status)
                        .font(.footnote)
                        .foregroundStyle(vm.status.hasPrefix("Error") ? .red : .green)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task {
                        if await vm.save(appState: appState) {
                            await MainActor.run { appState.checkAuthentication() }
                        }
                    }
                } label: {
                    Group {
                        if vm.isBusy {
                            ProgressView()
                        } else {
                            Text("Connect")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canContinue || vm.isBusy)
            }
            .padding()
            .animation(.easeInOut(duration: 0.2), value: vm.selectedSource)
        }
        .navigationTitle("Data Source")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var libreForm: some View {
        VStack(spacing: 12) {
            TextField("LibreLinkUp email", text: $vm.libreEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .fieldStyle()
            SecureField("LibreLinkUp password", text: $vm.librePassword)
                .textContentType(.password)
                .fieldStyle()
            Picker("Region", selection: $vm.libreRegion) {
                ForEach(DataSourceSetupViewModel.libreRegions, id: \.locale) { region in
                    Text(region.label).tag(region.locale)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var nightscoutForm: some View {
        VStack(spacing: 12) {
            TextField("Nightscout URL (https://...)", text: $vm.nightscoutURL)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .fieldStyle()
            SecureField("API secret (optional)", text: $vm.nightscoutSecret)
                .fieldStyle()
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
