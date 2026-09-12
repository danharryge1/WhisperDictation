import AVFoundation
import Cocoa
import ApplicationServices

final class PermissionManager: ObservableObject, @unchecked Sendable {
    static let shared = PermissionManager()

    @Published var microphoneGranted = false
    @Published var accessibilityGranted = false

    var allPermissionsGranted: Bool {
        microphoneGranted && accessibilityGranted
    }

    init() {
        checkPermissions()
    }

    func checkPermissions() {
        checkMicrophone()
        checkAccessibility()
    }

    // MARK: - Microphone

    func checkMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
        case .notDetermined:
            microphoneGranted = false
        case .denied, .restricted:
            microphoneGranted = false
        @unknown default:
            microphoneGranted = false
        }
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.microphoneGranted = granted
            }
        }
    }

    // MARK: - Accessibility

    func checkAccessibility() {
        let trusted = AXIsProcessTrusted()
        if Thread.isMainThread {
            accessibilityGranted = trusted
        } else {
            DispatchQueue.main.async { self.accessibilityGranted = trusted }
        }
    }

    /// Shows the system Accessibility prompt. Needed after an ad-hoc re-sign,
    /// when System Settings can still list the app while AXIsProcessTrusted is false.
    func promptAccessibilityIfNeeded() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if Thread.isMainThread {
            accessibilityGranted = trusted
        } else {
            DispatchQueue.main.async { self.accessibilityGranted = trusted }
        }
    }

    func openAccessibilitySettings() {
        promptAccessibilityIfNeeded()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
