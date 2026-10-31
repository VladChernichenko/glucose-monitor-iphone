import AVFoundation
import SwiftUI

/// What the food capture produced: a photo for the backend to analyse, or an on-device AR volume scan.
enum FoodCaptureResult {
    case photo(UIImage)
    case arScan(NutrientSummary)

    /// The AR scan as a meal-prep request with per-component weights, e.g. "prepare me for: rice 150 g";
    /// nil when nothing was recognised.
    static func mealPrepText(_ summary: NutrientSummary) -> String? {
        let items = summary.components
            .filter { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { BackendAPI.MealPlanItem(name: $0.label, grams: $0.massG) }
        return items.isEmpty ? nil : MealPlanRules.replanMessage(items)
    }
}

/// The capture part of the former Notes food scan, reused by the chat camera button: choose AR volume
/// scan, camera or library, then hand the result back. Analysis happens in the chat (meal prep).
struct FoodCaptureFlow: View {
    let onResult: (FoodCaptureResult) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showSourcePicker = true
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var showARScanner = false
    @State private var captured: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if showCamera || showLibrary {
                    Color.black.ignoresSafeArea()
                } else if showARScanner {
                    // Segmentation -> LiDAR volume -> local nutrition lookup, all on device.
                    ARFoodScannerView(
                        onResult: { summary in
                            Task { @MainActor in
                                showARScanner = false
                                onResult(.arScan(summary))
                                dismiss()
                            }
                        },
                        onDismiss: {
                            showARScanner = false
                            dismiss()
                        }
                    )
                    .ignoresSafeArea()
                } else {
                    // fullScreenCover needs a non-empty hierarchy underneath while the dialog is up.
                    Color(.systemBackground).ignoresSafeArea()
                }
            }
            .navigationTitle("Scan Food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog("Add food", isPresented: $showSourcePicker, titleVisibility: .visible) {
                Button("AR Volume Scan") { showARScanner = true }
                Button("Take Photo") { requestCameraAndOpen() }
                Button("Choose from Library") { showLibrary = true }
                Button("Cancel", role: .cancel) { dismiss() }
            }
            .fullScreenCover(isPresented: $showCamera, onDismiss: finishPicking) {
                CameraPickerView(isPresented: $showCamera, sourceType: .camera) { captured = $0 }
                    .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showLibrary, onDismiss: finishPicking) {
                CameraPickerView(isPresented: $showLibrary, sourceType: .photoLibrary) { captured = $0 }
                    .ignoresSafeArea()
            }
        }
    }

    /// Runs after the picker cover is gone, so dismissing this sheet does not race the cover.
    private func finishPicking() {
        if let image = captured { onResult(.photo(image)) }
        dismiss()
    }

    private func requestCameraAndOpen() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { if granted { showCamera = true } else { dismiss() } }
            }
        default:
            // Denied/restricted: open Settings so the user can re-enable it.
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            dismiss()
        }
    }
}

// MARK: - Camera Picker

struct CameraPickerView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var sourceType: UIImagePickerController.SourceType = .camera
    let onCapture: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(sourceType) ? sourceType : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPickerView
        init(_ parent: CameraPickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.isPresented = false
                return
            }
            // iOS-5 fix: never save food photos to the Camera Roll without consent.
            parent.onCapture(image)
            parent.isPresented = false
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}
