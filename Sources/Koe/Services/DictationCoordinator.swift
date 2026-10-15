import AppKit
import Carbon.HIToolbox
import Combine

@MainActor
final class DictationCoordinator: ObservableObject {
    static let shared = DictationCoordinator()

    @Published private(set) var statusText: String = "待機中"
    @Published private(set) var isProcessing: Bool = false

    private let speechManager: SpeechManager
    private let pasteService: PasteServing
    private let typer: LiveTyping
    private let overlay: OverlayPanel

    private var selectedTextForCorrection: String?
    /// 修正結果を貼るアプリ。話している間に前面が変わったら、別のアプリへ貼らない。
    private var correctionTargetPID: pid_t?
    private var completionTask: Task<Void, Never>?
    private var overlayDismissTask: Task<Void, Never>?
    private var speechSubscriptions: Set<AnyCancellable> = []

    /// 録音中だけ存在する。
    private struct LiveSession {
        var reconciler = LiveTextReconciler()
        /// 打ち込みを始めてよい時刻。録音キーの押下が確定するまでは nil で、短い fn タップでは何も打たない。
        var typingFrom: TimeInterval?
        /// パスワード欄へ移ったため、打ち込みをやめた。
        var interrupted = false
    }

    private var live: LiveSession?
    private var liveTimer: Timer?
    /// 認識結果が変わるたびに呼ばれる。ハンズフリーの無音タイムアウトを延ばすのに使う。
    var onSpeech: () -> Void = {}
    /// 入力ソースを英字に切り替えてから、前面アプリに切り替えが届くまで待つ時間。
    private static let inputSourceSettle: TimeInterval = 0.1
    /// 確定や取り消しで Command が離されるのを待つ上限。
    private static let modifierReleaseTimeout: TimeInterval = 3

    /// 完了のチェックは打ち込んだ文そのものが成功の合図なので短く、注意は読めるだけ残す。
    private static let doneLinger = 0.45
    private static let noticeLinger = 2.5
    private static let copiedLinger = 1.0

    private convenience init() {
        self.init(
            speechManager: .shared,
            pasteService: PasteService.shared,
            typer: KeystrokeTyper.shared,
            overlay: OverlayPanel()
        )
    }

    init(
        speechManager: SpeechManager,
        pasteService: PasteServing,
        typer: LiveTyping,
        overlay: OverlayPanel
    ) {
        self.speechManager = speechManager
        self.pasteService = pasteService
        self.typer = typer
        self.overlay = overlay

        speechManager.onRecognitionEnded = { [weak self] in
            guard let self, self.live != nil || self.selectedTextForCorrection != nil else { return }
            self.stopRecording()
            HotkeyManager.shared.resetState()
        }
        let state = overlay.overlayState
        speechManager.$transcript
            .sink { [weak self] transcript in
                state.transcript = transcript.text
                self?.liveTranscriptChanged(transcript)
                self?.onSpeech()
            }
            .store(in: &speechSubscriptions)
        speechManager.$level
            .sink { state.push(level: $0) }
            .store(in: &speechSubscriptions)
    }

    /// 録音だけを始め、オーバーレイは出さない。短い fn タップ（入力ソース切り替え）で画面がちらつかないようにするため。
    func startRecording() {
        Log.d("[DictationCoordinator] startRecording called (isProcessing=\(isProcessing), isRecording=\(speechManager.isRecording))")
        guard !isProcessing, !speechManager.isRecording else { return }
        overlayDismissTask?.cancel()
        overlayDismissTask = nil
        overlay.orderOut(nil)

        // パスワード欄では、読み上げた内容を打ち込んだり選択範囲を読んだりしない。
        if IsSecureEventInputEnabled() {
            Log.d("[DictationCoordinator] Secure input is enabled; not recording")
            overlay.update(.notice("パスワード入力中のため音声入力を止めています"))
            overlay.show()
            dismissOverlayAfterDelay(seconds: Self.noticeLinger)
            return
        }

        let selected = pasteService.getSelectedText()
        if selected != nil, let reason = OnDeviceLanguageModelService().unavailableReason {
            statusText = "選択範囲の修正は使えません"
            overlay.update(.notice("\(reason.message)。選択を解除してから音声入力してください"))
            overlay.show()
            dismissOverlayAfterDelay(seconds: Self.noticeLinger)
            return
        }
        selectedTextForCorrection = selected
        correctionTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Log.d("[DictationCoordinator] Selected text for correction: \(selected.map { "\($0.count) chars" } ?? "none")")

        do {
            try speechManager.startRecording(language: Config.recognitionLanguage, dictionary: Config.shared.dictionary)
            Log.d("[DictationCoordinator] Recording started")
            // 選択範囲の修正は、話し終えた指示で書き換えるため打ち込まずにまとめて処理する。
            if selected == nil {
                live = LiveSession()
                overlay.update(.typing(isHandsFree: false))
                statusText = "録音中..."
            } else {
                overlay.update(.correction(isHandsFree: false))
                statusText = "修正の指示を録音中..."
            }
        } catch {
            Log.d("[DictationCoordinator] startRecording error: \(error.localizedDescription)")
            statusText = "エラー: \(error.localizedDescription)"
            overlay.update(.notice(error.localizedDescription))
            overlay.show()
            selectedTextForCorrection = nil
            dismissOverlayAfterDelay(seconds: Self.noticeLinger)
        }
    }

    /// 0.25 秒以上押し続けた（短い fn タップではない）と確定した時点。
    func showRecordingOverlay() {
        guard speechManager.isRecording else { return }
        overlay.show()
        beginLiveTyping()
    }

    func lockHandsFree() {
        guard speechManager.isRecording else { return }
        statusText = "ハンズフリー録音中..."
        overlay.update(live != nil ? .typing(isHandsFree: true) : .correction(isHandsFree: true))
        overlay.show()
        beginLiveTyping()
    }

    func stopRecording() {
        Log.d("[DictationCoordinator] stopRecording called (isRecording=\(speechManager.isRecording))")
        guard speechManager.isRecording else { return }

        speechManager.stopRecording()
        play(.commit)
        isProcessing = true
        if live != nil {
            stopLiveTimer()
            completionTask = Task { await completeLiveTyping() }
        } else if let selected = selectedTextForCorrection {
            selectedTextForCorrection = nil
            overlay.update(.correcting)
            overlay.show()
            let target = correctionTargetPID
            completionTask = Task { await completeCorrection(of: selected, in: target) }
        }
    }

    /// 録音を捨てる。打ち込んだ文字も消す。
    func cancelRecording() {
        guard speechManager.isRecording else { return }
        Log.d("[DictationCoordinator] cancelRecording")
        // 短い fn タップ（入力ソースの切り替え）の取り消しは利用者の操作ではないので鳴らさない。
        if overlay.isVisible { play(.cancel) }
        speechManager.cancelRecording()
        if let session = live {
            stopLiveTimer()
            live = nil
            if session.typingFrom != nil, !session.interrupted {
                isProcessing = true
                completionTask = Task { await eraseLiveTyping(session) }
            } else {
                typer.end()
            }
        }
        selectedTextForCorrection = nil
        statusText = "待機中"
        overlay.dismiss()
    }

    /// 利用者のキー入力やクリックで入力位置が動いたので、打った文字はその場に残し、続きを動いた先に打つ。
    /// 打ち直すと動いた先の文字を消してしまうため、打った文字には戻らない。
    /// キー監視のコールバックから同期で呼ばれるので、軽い処理だけにする。
    func liveInputPositionMoved() {
        guard live != nil else { return }
        Log.d("[DictationCoordinator] User input during live typing; continue at the new position")
        live?.reconciler.moveToNewPosition()
        // クリックした先へフォーカスが移りきる前に、元の入力欄へ続きを打たないよう少し待つ。
        if live?.typingFrom != nil { live?.typingFrom = Self.now + Self.inputSourceSettle }
    }

    private func eraseLiveTyping(_ session: LiveSession) async {
        defer {
            typer.end()
            isProcessing = false
        }
        var session = session
        guard await waitUntilTypable() else {
            Log.d("[DictationCoordinator] Modifiers still held; leave typed text")
            overlay.update(.notice("修飾キーが押されたままのため、入力した文字を消しませんでした"))
            overlay.show()
            dismissOverlayAfterDelay(seconds: Self.noticeLinger)
            return
        }
        // 打った後に入力欄が変わっていたら、移った先の文字を消さないよう何もしない。
        guard !typer.followFocus() else { return }
        _ = typer.apply(session.reconciler.cancel())
    }

    private func waitUntilTypable() async -> Bool {
        let deadline = Self.now + Self.modifierReleaseTimeout
        while !typer.canType {
            guard Self.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    func pasteLastTranscript() {
        guard let lastTranscript = Config.shared.history.first, !speechManager.isRecording, !isProcessing else { return }
        Log.d("[DictationCoordinator] pasteLastTranscript (\(lastTranscript.count) chars)")
        pasteService.paste(text: lastTranscript)
    }

    func copyFromHistory(_ text: String) {
        pasteService.copy(text: text)
        // 録音中や処理中はオーバーレイがその状態を表しているので、上書きしない。
        guard !speechManager.isRecording, !isProcessing else { return }
        overlay.update(.copied)
        overlay.show()
        dismissOverlayAfterDelay(seconds: Self.copiedLinger)
    }

    private func beginLiveTyping() {
        guard live != nil, live?.typingFrom == nil else { return }
        startTyping()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushLive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func startTyping() {
        typer.begin()
        live?.typingFrom = Self.now + Self.inputSourceSettle
    }

    private func stopLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    private func liveTranscriptChanged(_ transcript: Transcript) {
        guard live != nil else { return }
        live?.reconciler.observe(transcript, at: Self.now)
        flushLive()
    }

    /// 安定した分だけを打ち込む。時間が経つだけで安定する文字もあるため、タイマーからも呼ぶ。
    private func flushLive() {
        let now = Self.now
        guard let session = live, !session.interrupted, let typingFrom = session.typingFrom, now >= typingFrom,
              typer.canType else { return }
        if typer.followFocus() {
            // 移った先で入力ソースを英字に切り替えた場合に、切り替えが届くのを待ってから打つ。
            live?.reconciler.moveToNewPosition()
            live?.typingFrom = now + Self.inputSourceSettle
            return
        }
        guard let ops = live?.reconciler.sync(at: now) else { return }
        if !typer.apply(ops) {
            live?.interrupted = true
            stopLiveTimer()
            overlay.update(.notice("パスワード入力欄に移ったため入力を止めました"))
        }
    }

    private func completeLiveTyping() async {
        defer { isProcessing = false }
        if live?.typingFrom == nil {
            startTyping()
            try? await Task.sleep(for: .seconds(Self.inputSourceSettle))
        }
        let final = await speechManager.finalTranscript()
        let typable = await waitUntilTypable()
        guard var session = live else { return }
        live = nil
        if typable, !session.interrupted, typer.followFocus() {
            session.reconciler.moveToNewPosition()
            try? await Task.sleep(for: .seconds(Self.inputSourceSettle))
        }
        session.reconciler.observe(final, at: Self.now)
        let ops = session.reconciler.finish()
        let typedAll = !session.interrupted && typable && typer.apply(ops)
        typer.end()
        Log.d("[DictationCoordinator] Live typing finished (final=\(final.text.count) chars, typedAll=\(typedAll))")

        guard !final.text.isEmpty else {
            showNoSpeechNotice()
            return
        }
        Config.shared.remember(final.text)
        if let error = speechManager.lastError {
            statusText = "音声認識が中断しました"
            overlay.update(.notice("認識済みの文を保存しました（\(error.localizedDescription)）"))
            dismissOverlayAfterDelay(seconds: Self.noticeLinger)
        } else if typedAll {
            statusText = "完了"
            overlay.update(.done)
            dismissOverlayAfterDelay(seconds: Self.doneLinger)
        } else {
            statusText = "完了（途中で中断）"
            let reason = typable ? "パスワード入力欄に移ったため" : "修飾キーが押されたままのため"
            overlay.update(.notice("\(reason)途中で止めました。⌃⌘V で全文を入力できます"))
            dismissOverlayAfterDelay(seconds: Self.noticeLinger)
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func completeCorrection(of selectedText: String, in targetPID: pid_t?) async {
        defer { isProcessing = false }
        let instruction = await speechManager.finalTranscript().text
        guard !instruction.isEmpty else {
            showNoSpeechNotice()
            return
        }
        Log.d("[DictationCoordinator] Correcting \(selectedText.count) chars")
        let corrector = OnDeviceLanguageModelService()
        if let reason = corrector.unavailableReason {
            statusText = "修正できません"
            overlay.update(.notice("\(reason.message)のため修正できません"))
            dismissOverlayAfterDelay(seconds: Self.noticeLinger)
            return
        }
        statusText = "修正中..."
        do {
            let corrected = try await corrector.correct(selectedText: selectedText, instruction: instruction)
            Config.shared.remember(corrected)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
                statusText = "完了（貼り付けを中止）"
                overlay.update(.notice("入力先が変わったため貼り付けませんでした。⌃⌘V で入力できます"))
                dismissOverlayAfterDelay(seconds: Self.noticeLinger)
                return
            }
            pasteService.paste(text: corrected)
            statusText = "完了"
            overlay.update(.done)
            dismissOverlayAfterDelay(seconds: Self.doneLinger)
        } catch where error is CancellationError {
            overlay.dismiss()
        } catch {
            statusText = "修正エラー"
            overlay.update(.notice("修正できませんでした（\(error.localizedDescription)）"))
            dismissOverlayAfterDelay(seconds: Self.noticeLinger)
        }
    }

    private func showNoSpeechNotice() {
        statusText = "テキストが認識されませんでした"
        if let error = speechManager.lastError {
            overlay.update(.notice("音声認識を始められませんでした（\(error.localizedDescription)）"))
        } else {
            overlay.update(.notice("声を聞き取れませんでした。もう少し長く話してください"))
        }
        dismissOverlayAfterDelay(seconds: Self.noticeLinger)
    }

    private enum Sound: String {
        case commit = "Pop"
        case cancel = "Bottle"
    }

    private func play(_ sound: Sound) {
        guard Config.shared.soundEffects, let player = NSSound(named: sound.rawValue) else { return }
        player.volume = 0.3
        player.play()
    }

    private func dismissOverlayAfterDelay(seconds: Double) {
        overlayDismissTask?.cancel()
        overlayDismissTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled {
                self.overlay.dismiss()
            }
        }
    }
}
