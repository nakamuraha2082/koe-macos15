import SwiftUI

@main
struct KoeApp: App {
    private static var didScheduleHotkeySetup = false

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var speechManager = SpeechManager.shared
    private let hotkeyManager = HotkeyManager.shared
    @ObservedObject private var config = Config.shared
    @ObservedObject private var coordinator = DictationCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                config: config,
                coordinator: coordinator,
                openSettings: openSettings
            )
        } label: {
            if speechManager.isRecording {
                Image(systemName: "waveform.circle.fill")
            } else {
                Image(nsImage: Self.menuBarIcon)
            }
        }
    }

    private static let menuBarIcon: NSImage = {
        let bundleResourcePath = Bundle.main.resourcePath ?? ""
        let candidates = [
            bundleResourcePath + "/MenuBarIcon@2x.png",
            bundleResourcePath + "/MenuBarIcon.png",
        ]
        for path in candidates {
            if let img = NSImage(contentsOfFile: path) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                return img
            }
        }
        return NSImage(systemSymbolName: "waveform", accessibilityDescription: "koe!")!
    }()

    private func openSettings() {
        appDelegate.showSettings()
    }

    private func setupHotkey() {
        Log.d("[KoeApp] setupHotkey")
        coordinator.onSpeech = { [hotkeyManager] in hotkeyManager.noteSpeech() }
        hotkeyManager.start(
            perform: { [self] effect in
                switch effect {
                case .startRecording: coordinator.startRecording()
                case .showOverlay: coordinator.showRecordingOverlay()
                case .lockHandsFree: coordinator.lockHandsFree()
                case .commit: coordinator.stopRecording()
                case .cancel: coordinator.cancelRecording()
                }
            },
            pasteLastTranscript: { [self] in
                coordinator.pasteLastTranscript()
            },
            liveInputPositionMoved: { [self] in
                coordinator.liveInputPositionMoved()
            }
        )
    }

    init() {
        guard !Self.didScheduleHotkeySetup, SnapshotRenderer.requestedDirectory == nil,
              FileTranscriptionProbe.requestedFile == nil else { return }
        Self.didScheduleHotkeySetup = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            setupHotkey()
        }
    }
}

struct MenuContent: View {
    @ObservedObject var config: Config
    @ObservedObject var coordinator: DictationCoordinator
    let openSettings: () -> Void

    var body: some View {
        Text(coordinator.statusText)

        Divider()

        Section("ショートカット") {
            Text("\(config.triggerKey.displayName) を押している間だけ録音")
            Text("\(config.triggerKey.displayName) を2回押してハンズフリー")
            Text("esc で取り消し")
        }
        Button("直前の入力を貼り直す") {
            coordinator.pasteLastTranscript()
        }
        .keyboardShortcut("v", modifiers: [.control, .command])
        .disabled(config.history.isEmpty || coordinator.isProcessing)

        Menu("履歴") {
            ForEach(Array(config.history.enumerated()), id: \.offset) { _, text in
                Button(Self.historyTitle(text)) {
                    coordinator.copyFromHistory(text)
                }
            }
            Divider()
            Button("履歴を消去", action: config.clearHistory)
        }
        .disabled(config.history.isEmpty)

        let missing = Permission.missing
        if !missing.isEmpty {
            Divider()
            Section("許可が必要です") {
                ForEach(missing) { permission in
                    Button {
                        permission.openSettings()
                    } label: {
                        Label("\(permission.title)を許可…", systemImage: "exclamationmark.triangle")
                    }
                }
            }
        }

        Divider()

        Button("設定…", action: openSettings)
            .keyboardShortcut(",")
        Button("終了") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private static func historyTitle(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 30 ? line.prefix(30) + "…" : line
    }
}
