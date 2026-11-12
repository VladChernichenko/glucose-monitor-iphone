import AVFoundation
import Photos
import SwiftUI
import UIKit

/// Camera permission gate used before opening the meal camera.
enum FoodCameraAuth {
    static func requestAndRun(onAuthorized: @escaping () -> Void, onDenied: @escaping () -> Void = {}) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            onAuthorized()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { onAuthorized() } else { onDenied() }
                }
            }
        default:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            onDenied()
        }
    }
}

/// Classic bottom action sheet. SwiftUI `confirmationDialog` presents as a top/center card on current iOS.
enum FoodSourcePicker {
    static func present(onCamera: @escaping () -> Void, onLibrary: @escaping () -> Void) {
        guard let presenter = topViewController() else { return }
        let sheet = UIAlertController(title: "Add food", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Take Photo", style: .default) { _ in onCamera() })
        sheet.addAction(UIAlertAction(title: "Choose from Library", style: .default) { _ in onLibrary() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            let view = presenter.view!
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
        return root.map(topMost(from:))
    }

    private static func topMost(from controller: UIViewController) -> UIViewController {
        if let presented = controller.presentedViewController {
            return topMost(from: presented)
        }
        if let nav = controller as? UINavigationController, let visible = nav.visibleViewController {
            return topMost(from: visible)
        }
        if let tab = controller as? UITabBarController, let selected = tab.selectedViewController {
            return topMost(from: selected)
        }
        return controller
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
