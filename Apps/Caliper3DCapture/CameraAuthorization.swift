import AVFoundation
import Caliper3DCore

/// AVFoundation is used only for authorization, never a competing capture session.
struct CameraAuthorization: CameraPermissionService {
    func status() async -> CameraPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: .notDetermined
        case .authorized: .allowed
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }
    func request() async -> CameraPermission {
        guard await status() == .notDetermined else { return await status() }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return await status()
    }
}
