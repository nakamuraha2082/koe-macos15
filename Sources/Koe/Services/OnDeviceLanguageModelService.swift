import Foundation

enum LanguageModelUnavailableReason: Error, Equatable {
    case requiresMacOS26

    var message: String { "macOS 15 互換版では非対応" }
}

/// macOS 15 SDK には FoundationModels がないため、選択範囲は変更しない。
final class OnDeviceLanguageModelService {
    var unavailableReason: LanguageModelUnavailableReason? { .requiresMacOS26 }

    func correct(selectedText: String, instruction: String) async throws -> String {
        throw LanguageModelUnavailableReason.requiresMacOS26
    }
}
