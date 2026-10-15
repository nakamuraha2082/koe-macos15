import AVFoundation
import Speech

/// マイク（またはファイル）の音を SFSpeechRecognizer に流し、認識の途中経過を `transcript` として公開する。
@MainActor
final class SpeechManager: ObservableObject {
    static let shared = SpeechManager()

    @Published private(set) var isRecording = false
    @Published private(set) var transcript = Transcript()
    /// 録音中のマイク音量（0〜1）。オーバーレイの棒グラフ用。
    @Published private(set) var level: Float = 0
    /// 直近の録音で認識を始められなかった理由。
    private(set) var lastError: Error?

    private let levelMeter = LevelMeter()

    private var audioEngine = AVAudioEngine()
    private var captureSession: AVCaptureSession?
    private var captureDelegate: AudioCaptureDelegate?
    private var fileFeeder: Task<Void, Never>?
    private var audioInput: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionResults: AsyncThrowingStream<SFSpeechRecognitionResult, Error>.Continuation?
    private var limitTask: Task<Void, Never>?
    /// 認識終了・時間制限・エラー時は、入力済みの文を確定して録音を終了する。
    var onRecognitionEnded: () -> Void = {}
    /// 前の録音の結果が遅れて届いても、今の録音に混ぜないための番号。
    private var session = 0
    private var dictionary: [DictionaryEntry] = []

    private init() {
        levelMeter.onLevel = { [weak self] level in
            guard let self, self.isRecording else { return }
            self.level = level
        }
    }

    /// オンデバイス認識が使える場合だけ録音を開始する。ネットワーク認識へは切り替えない。
    /// `file` を渡すとマイクの代わりにそのファイルを実時間の速さで流す（動作確認用）。
    func startRecording(language: String, dictionary: [DictionaryEntry], file: URL? = nil) throws {
        cancelRecording()
        self.dictionary = dictionary
        lastError = nil
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw SpeechError.permissionRequired
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.supportsOnDeviceRecognition else {
            throw SpeechError.unsupportedLanguage
        }
        self.recognizer = recognizer

        let (audio, input) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        session += 1
        let current = session
        lastError = nil

        do {
            if let file {
                try startFeeding(file: file, into: input)
            } else {
                try startCapture(into: input)
            }
        } catch {
            input.finish()
            stopAudioCapture()
            self.recognizer = nil
            throw error
        }

        audioInput = input
        analysisTask = Task { [weak self] in
            await self?.analyze(audio, session: current)
        }
        isRecording = true
        if file == nil {
            limitTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(55)) } catch { return }
                guard let self, self.session == current, self.isRecording else { return }
                self.onRecognitionEnded()
                self.stopRecording()
            }
        }
        Log.d("[SpeechManager] Recording started (session=\(current))")
    }

    /// 音の入力を止める。最終結果は `finalTranscript()` で待つ。
    func stopRecording() {
        guard isRecording else { return }
        limitTask?.cancel()
        limitTask = nil
        Log.d("[SpeechManager] Stopping recording")
        stopAudioCapture()
        audioInput?.finish()
        audioInput = nil
        isRecording = false
    }

    /// 入力し終えた音の認識が確定するのを待つ。認識が止まった場合に備えて上限を設ける。
    func finalTranscript(timeout: Duration = .seconds(3)) async -> Transcript {
        guard let task = analysisTask else { return transcript }
        analysisTask = nil
        let current = session
        // OS から確定結果が戻らなくても、次の録音を受け付けられるようにする。
        // 期限が来たらそこまでの認識結果で打ち切り、遅れて届く結果は session を進めて捨てる。
        let finished = await Self.first(of: { await task.value }, orAfter: timeout)
        guard current == session else { return Transcript() }
        guard !finished else { return transcript }
        Log.d("[SpeechManager] Finalizing timed out; using the transcript so far")
        let result = transcript
        session += 1
        stopAudioCapture()
        audioInput?.finish()
        audioInput = nil
        task.cancel()
        limitTask?.cancel()
        limitTask = nil
        isRecording = false
        lastError = SpeechError.finalizationTimedOut
        finishRecognition()
        return result
    }

    /// work が timeout 内に終われば true。終わらなくても work の完了は待たない。
    private static func first(of work: @escaping @MainActor () async -> Void, orAfter timeout: Duration) async -> Bool {
        final class Once {
            var continuation: CheckedContinuation<Bool, Never>?
            func resume(_ value: Bool) {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            Task { @MainActor in
                await work()
                once.resume(true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume(false)
            }
        }
    }

    func cancelRecording() {
        stopAudioCapture()
        audioInput?.finish()
        audioInput = nil
        session += 1
        limitTask?.cancel()
        limitTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        finishRecognition()
        if isRecording { Log.d("[SpeechManager] Recording cancelled") }
        isRecording = false
        transcript = Transcript()
    }

    private func finishRecognition() {
        recognitionResults?.finish()
        recognitionResults = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil
    }

    private func analyze(_ audio: AsyncStream<AVAudioPCMBuffer>, session current: Int) async {
        guard current == session, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = Array(dictionary.words.prefix(100))
        recognitionRequest = request

        let (results, continuation) = AsyncThrowingStream.makeStream(of: SFSpeechRecognitionResult.self)
        recognitionResults = continuation
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                continuation.yield(result)
                if result.isFinal { continuation.finish(); return }
            }
            if let error { continuation.finish(throwing: error) }
        }
        let feeder = Task {
            for await buffer in audio {
                guard !Task.isCancelled else { break }
                request.append(buffer)
            }
            request.endAudio()
        }
        defer { feeder.cancel() }
        do {
            for try await result in results {
                guard current == session, !Task.isCancelled else { return }
                let text = dictionary.corrected(result.bestTranscription.formattedString)
                Log.d("[SpeechManager] Result chars=\(text.count), final=\(result.isFinal)")
                transcript.receiveCumulative(text, isFinal: result.isFinal)
            }
        } catch {
            guard current == session else { return }
            Log.d("[SpeechManager] Recognition error: \(error)")
            lastError = error
        }
        guard current == session else { return }
        finishRecognition()
        if isRecording {
            onRecognitionEnded()
            stopRecording()
        }
    }

    // MARK: - 音の取り込み

    /// デバイス指定がある場合は AVCaptureSession、なければ AVAudioEngine。
    private func startCapture(into input: AsyncStream<AVAudioPCMBuffer>.Continuation) throws {
        let selectedUID = Config.shared.audioInputDeviceUID
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
        if !selectedUID.isEmpty, let device = discovery.devices.first(where: { $0.uniqueID == selectedUID }) {
            try startCaptureSession(device: device, into: input)
        } else {
            if !selectedUID.isEmpty {
                Log.d("[SpeechManager] デバイスが見つかりません: \(selectedUID)、システムデフォルトを使用")
            }
            try startAudioEngine(into: input)
        }
    }

    private func startAudioEngine(into input: AsyncStream<AVAudioPCMBuffer>.Continuation) throws {
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        Log.d("[SpeechManager] AVAudioEngine フォーマット: ch=\(format.channelCount), rate=\(format.sampleRate)")

        let meter = levelMeter
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            input.yield(buffer)
            meter.feed(decibels: LevelMeter.decibels(of: buffer))
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func startCaptureSession(device: AVCaptureDevice, into input: AsyncStream<AVAudioPCMBuffer>.Continuation) throws {
        let session = AVCaptureSession()
        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(deviceInput) else { throw SpeechError.deviceUnavailable }
        session.addInput(deviceInput)

        let output = AVCaptureAudioDataOutput()
        let meter = levelMeter
        let delegate = AudioCaptureDelegate { sampleBuffer, connection in
            if let buffer = AVAudioPCMBuffer.copying(sampleBuffer) {
                input.yield(buffer)
            }
            if let decibels = connection.audioChannels.first?.averagePowerLevel {
                meter.feed(decibels: decibels)
            }
        }
        captureDelegate = delegate
        output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "com.koe.audiocapture"))
        guard session.canAddOutput(output) else { throw SpeechError.deviceUnavailable }
        session.addOutput(output)

        session.startRunning()
        captureSession = session
        Log.d("[SpeechManager] AVCaptureSession で録音開始: \(device.localizedName) (\(device.uniqueID))")
    }

    private func startFeeding(file url: URL, into input: AsyncStream<AVAudioPCMBuffer>.Continuation) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        fileFeeder = Task.detached {
            while !Task.isCancelled,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                  (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
                input.yield(buffer)
                try? await Task.sleep(for: .seconds(Double(buffer.frameLength) / format.sampleRate))
            }
            input.finish()
        }
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        if let captureSession, captureSession.isRunning {
            captureSession.stopRunning()
        }
        captureSession = nil
        captureDelegate = nil
        fileFeeder?.cancel()
        fileFeeder = nil
        level = 0
    }

    enum SpeechError: LocalizedError {
        case finalizationTimedOut
        case permissionRequired
        case unsupportedLanguage
        case deviceUnavailable

        var errorDescription: String? {
            switch self {
            case .finalizationTimedOut:
                return "確定待ちが時間切れになったため、認識済みの文で終了しました"
            case .permissionRequired:
                return "システム設定で Koe15 の音声認識を許可してください"
            case .unsupportedLanguage:
                return "Mac 内の日本語認識モデルが使えません。システム設定の音声入力を日本語で有効にしてから再試行してください"
            case .deviceUnavailable:
                return "選択されたマイクデバイスが利用できません"
            }
        }
    }
}

private extension AVAudioPCMBuffer {
    static func copying(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

/// AVCaptureSession のオーディオデータを受け取るデリゲート
private final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let handler: (CMSampleBuffer, AVCaptureConnection) -> Void

    init(handler: @escaping (CMSampleBuffer, AVCaptureConnection) -> Void) {
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler(sampleBuffer, connection)
    }
}

/// 音声スレッドで受け取った音量を、メインスレッドへ約 25Hz に間引いて渡す。
private final class LevelMeter: @unchecked Sendable {
    var onLevel: @MainActor (Float) -> Void = { _ in }
    private var lastSent: TimeInterval = 0

    func feed(decibels: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSent >= 0.04 else { return }
        lastSent = now
        // 話し声はおおむね -50〜-10 dBFS に収まるため、その範囲を 0〜1 に広げる。
        let level = min(max((decibels + 50) / 40, 0), 1)
        DispatchQueue.main.async { [onLevel] in
            MainActor.assumeIsolated { onLevel(level) }
        }
    }

    static func decibels(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        return 20 * log10(max((sum / Float(count)).squareRoot(), 1e-8))
    }
}
