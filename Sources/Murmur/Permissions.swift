import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

enum Permissions {
    /// Needed for the keyboard event tap and for posting Cmd-V / keystrokes.
    static var accessibility: Bool { AXIsProcessTrusted() }
    /// Some macOS setups also gate keyboard event taps behind Input Monitoring.
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }
    static var microphone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func requestOnLaunch() {
        if !accessibility {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    static func requestInputMonitoring() {
        if !inputMonitoring { _ = CGRequestListenEventAccess() }
    }

    /// pane: "Privacy_Accessibility", "Privacy_ListenEvent" or "Privacy_Microphone".
    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
