import Foundation

enum Log {
    private static let logFile: FileHandle? = {
        // 認識した文の長さや操作の記録が他のユーザーから読めないよう、共有の /tmp ではなく自分だけが読める場所に置く。
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Koe15")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("koe.log").path
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        return FileHandle(forWritingAtPath: path)
    }()

    static func d(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            logFile?.seekToEndOfFile()
            logFile?.write(data)
        }
        // Also stderr so it shows in terminal
        fputs(line, stderr)
    }
}
