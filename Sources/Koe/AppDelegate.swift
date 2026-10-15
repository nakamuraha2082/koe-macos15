import Cocoa
import Speech
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = SnapshotRenderer.requestedDirectory {
            MainActor.assumeIsolated { SnapshotRenderer.renderAll(to: directory) }
            exit(0)
        }
        if let file = FileTranscriptionProbe.requestedFile {
            Task { @MainActor in
                let success = await FileTranscriptionProbe.run(file: file)
                exit(success ? 0 : 1)
            }
            return
        }
        Log.d("[AppDelegate] Launch started \(appVersionDescription)")
        showSettings()
        checkAllPermissions()
    }

    @MainActor
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Koe15 設定"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { KeystrokeTyper.shared.restoreInputSource() }
    }

    private var appVersionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "version=\(version) build=\(build)"
    }

    private func checkAllPermissions() {
        // 1. Accessibility
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let accessibilityGranted = AXIsProcessTrustedWithOptions(axOptions)
        Log.d("[AppDelegate] Accessibility: \(accessibilityGranted)")

        // 2. Microphone
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.d("[AppDelegate] Microphone: \(micStatus.rawValue)")
        if micStatus != .authorized {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.d("[AppDelegate] Microphone granted: \(granted)")
            }
        }

        // 3. Speech Recognition
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        Log.d("[AppDelegate] SpeechRecognition: \(speechStatus.rawValue)")
        if speechStatus != .authorized {
            SFSpeechRecognizer.requestAuthorization { status in
                Log.d("[AppDelegate] SpeechRecognition granted: \(status.rawValue)")
            }
        }
    }

}
