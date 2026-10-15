import Combine
import Foundation

/// `--transcribe-file <path>` で起動すると、マイクの代わりに音声ファイルを実時間で本番と同じ認識経路へ流し、
/// 途中結果・確定結果と、リアルタイム入力が打ち込む操作を時刻付きで標準出力へ書いて終了する。キー入力は送らない。
@MainActor
enum FileTranscriptionProbe {
    nonisolated static var requestedFile: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--transcribe-file"), index + 1 < arguments.count else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    /// `--dictionary Slack=スラック,仕様` の形で、保存済みの辞書の代わりに使う辞書を渡す。`=` の右は誤認識パターン。
    private static var requestedDictionary: [DictionaryEntry] {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--dictionary"), index + 1 < arguments.count else { return [] }
        return arguments[index + 1].split(separator: ",").map { item in
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            return DictionaryEntry(word: parts[0], misrecognitions: parts.count > 1 ? parts[1] : "")
        }
    }

    /// 録音キーの押下が確定する（0.25 秒）までと入力ソースの切り替え待ち（0.1 秒）の間は打たない、本番と同じ扱い。
    private static let typingFrom: TimeInterval = 0.35

    static func run(file: URL) async -> Bool {
        let speech = SpeechManager.shared
        let start = ProcessInfo.processInfo.systemUptime
        var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - start }
        var reconciler = LiveTextReconciler()
        var field = ""
        var last = Transcript()

        func log(_ message: String) {
            print(String(format: "[%6.2fs] ", elapsed) + message)
        }
        func apply(_ ops: [LiveTextOp]) {
            guard !ops.isEmpty else { return }
            for op in ops {
                switch op {
                case .backspace(let count): field = String(field.dropLast(count))
                case .type(let text): field += text
                }
            }
            log("ops \(ops)  field=\"\(field)\"")
        }
        func flush() {
            guard elapsed >= typingFrom else { return }
            apply(reconciler.sync(at: elapsed))
        }

        let subscription = speech.$transcript.sink { transcript in
            guard transcript != last else { return }
            if transcript.finalized != last.finalized {
                log("final    \"\(transcript.finalized.dropFirst(last.finalized.count))\"")
            }
            if transcript.volatile != last.volatile, !transcript.volatile.isEmpty {
                log("volatile \"\(transcript.volatile)\"")
            }
            last = transcript
            reconciler.observe(transcript, at: elapsed)
            flush()
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { flush() }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer {
            timer.invalidate()
            subscription.cancel()
        }

        do {
            try speech.startRecording(language: Config.recognitionLanguage, dictionary: requestedDictionary, file: file)
        } catch {
            print("failed to start: \(error.localizedDescription)")
            return false
        }
        log("started \(file.lastPathComponent) language=\(Config.recognitionLanguage) dictionary=\(requestedDictionary.map { "\($0.word)=\($0.misrecognitions)" })")
        let final = await speech.finalTranscript(timeout: .seconds(120))
        timer.invalidate()
        subscription.cancel()
        log("finished")
        if let error = speech.lastError {
            print("error: \(error)")
        }
        reconciler.observe(final, at: elapsed)
        apply(reconciler.finish())
        print("final transcript: \"\(final.text)\"")
        print("field matches final transcript: \(field == final.text)")
        return speech.lastError == nil && !final.text.isEmpty && field == final.text
    }
}
