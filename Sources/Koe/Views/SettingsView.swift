import AVFoundation
import SwiftUI

struct AudioInputDevice: Identifiable {
    let id: String  // uniqueID（空文字 = システムデフォルト）
    let name: String
}

struct SettingsView: View {
    @ObservedObject var config = Config.shared

    @State private var modelUnavailableReason = OnDeviceLanguageModelService().unavailableReason
    @State private var audioInputDevices: [AudioInputDevice] = []
    @State private var grantedPermissions: Set<Permission> = []
    @State private var isTestingSpeech = false
    @State private var speechTestResult = ""

    var body: some View {
        Form {
            inputSection
            Section("音声認識の確認") {
                Button(isTestingSpeech ? "確認中…" : "サンプル音声で確認") {
                    isTestingSpeech = true
                    speechTestResult = ""
                    Task { @MainActor in
                        defer { isTestingSpeech = false }
                        guard let file = Bundle.main.url(forResource: "SpeechSample", withExtension: "aiff") else {
                            speechTestResult = "検査用音声が見つかりません"
                            return
                        }
                        let success = await FileTranscriptionProbe.run(file: file)
                        let text = SpeechManager.shared.transcript.text
                        speechTestResult = success ? "成功: \(text)" : "確認失敗: \(SpeechManager.shared.lastError?.localizedDescription ?? "音声認識の権限・モデルを確認してください")"
                    }
                }
                .disabled(isTestingSpeech || SpeechManager.shared.isRecording || DictationCoordinator.shared.isProcessing)
                Text(speechTestResult.isEmpty ? "マイクを使わず、付属の日本語音声で確認します。文字は他のアプリに入力しません。" : speechTestResult)
                    .settingsFootnote()
            }
            dictionarySection
            Section("一般") {
                Toggle("効果音", isOn: $config.soundEffects)
                Toggle("ログイン時に起動", isOn: $config.launchAtLogin)
            }
            permissionSection
        }
        .formStyle(.grouped)
        // 13 インチの画面にも収まる高さに抑え、はみ出す分はフォームの中でスクロールさせる。
        .frame(width: 520, height: 640)
        .onAppear {
            refreshAudioDevices()
            refreshSystemState()
        }
        // システム設定で許可してから戻ってきたときに表示を更新する。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshSystemState()
        }
    }

    private var inputSection: some View {
        Section {
            LabeledContent("音声認識", value: "Mac 内で処理（macOS 15 互換版）")
            Text("1回の録音は最大55秒です。続きはもう一度録音してください。")
                .settingsFootnote()

            Picker("録音キー", selection: $config.triggerKey) {
                ForEach(TriggerKey.allCases) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .onChange(of: config.triggerKey) { _, _ in
                HotkeyManager.shared.resetState()
            }

            Picker("マイク", selection: $config.audioInputDeviceUID) {
                Text("システムデフォルト").tag("")
                ForEach(audioInputDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }

            LabeledContent {
                if let reason = modelUnavailableReason {
                    Label("使えません（\(reason.message)）", systemImage: "exclamationmark.circle.fill")
                        .labelStyle(StatusLabelStyle(tint: .orange))
                } else {
                    Label("使えます", systemImage: "checkmark.circle.fill")
                        .labelStyle(StatusLabelStyle(tint: .green))
                }
            } label: {
                Text("選択範囲の修正")
                Text("音声指示での書き換えには macOS 26 以降が必要です")
            }
        } header: {
            Text("入力")
        } footer: {
            if config.triggerKey == .fn {
                Text("fn で絵文字ピッカーなどが開く場合は、システム設定 › キーボードの「🌐キーを押して」を「何もしない」にしてください。")
                    .settingsFootnote()
            }
        }
    }

    private var dictionarySection: some View {
        Section {
            ForEach($config.dictionary) { $entry in
                HStack(spacing: 6) {
                    TextField("正しい表記", text: $entry.word, prompt: Text("正しい表記"))
                    TextField("誤認識", text: $entry.misrecognitions, prompt: Text("誤認識（カンマ区切り・任意）"))
                    Button {
                        config.dictionary.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("この語を削除")
                }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }
            Button("語を追加") {
                config.dictionary.append(DictionaryEntry())
            }
        } header: {
            Text("辞書")
        } footer: {
            Text("正しい表記は聞き取りの手がかりになります。誤認識に書いた文字が出たら、正しい表記に置き換えて入力します。次の録音から反映されます。")
                .settingsFootnote()
        }
    }

    private var permissionSection: some View {
        Section("権限") {
            ForEach(Permission.allCases) { permission in
                LabeledContent {
                    HStack(spacing: 10) {
                        if grantedPermissions.contains(permission) {
                            Label("許可済み", systemImage: "checkmark.circle.fill")
                                .labelStyle(StatusLabelStyle(tint: .green))
                        } else {
                            Label("未許可", systemImage: "exclamationmark.circle.fill")
                                .labelStyle(StatusLabelStyle(tint: .orange))
                        }
                        Button("開く") { permission.openSettings() }
                    }
                } label: {
                    Text(permission.title)
                    Text(permission.purpose)
                }
            }
        }
    }

    private func refreshSystemState() {
        grantedPermissions = Set(Permission.allCases.filter(\.isGranted))
        modelUnavailableReason = OnDeviceLanguageModelService().unavailableReason
    }

    private func refreshAudioDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        audioInputDevices = session.devices.map {
            AudioInputDevice(id: $0.uniqueID, name: $0.localizedName)
        }
    }
}

private struct StatusLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(tint)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

private extension Text {
    func settingsFootnote() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}
