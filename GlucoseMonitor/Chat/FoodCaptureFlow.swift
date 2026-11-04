import AVFoundation
import Photos
import SwiftUI

/// A photo for the backend to recognise. The catalog on the server supplies the nutrients.
enum FoodCaptureResult {
    case photo(UIImage)
}

/// Camera or library. Analysis happens after the photo is sent.
struct FoodCaptureFlow: View {
    let onResult: (FoodCaptureResult) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var showSourcePicker = true
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var captured: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if showCamera || showLibrary {
                    Color.black.ignoresSafeArea()
                } else {
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
            if parent.sourceType == .camera {
                MealPhotoLibrary.save(image)
            }
            parent.onCapture(image)
            parent.isPresented = false
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}

/// Writes a camera meal photo into the user's photo library. A picture chosen from the library is already there.
enum MealPhotoLibrary {
    static func save(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        }
    }
}
