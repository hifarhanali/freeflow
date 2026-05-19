import Foundation
import WhisperKit
import os.log

private let log = OSLog(subsystem: "com.zachlatta.freeflow", category: "WhisperKit")

// Local on-device transcription using WhisperKit (Apple Neural Engine).
// Model is downloaded to ~/Library/Application Support/huggingface/... on first use.
final class WhisperKitTranscriptionService {

    // Model size options exposed in Settings. Larger = more accurate, slower first load.
    static let availableModels: [(id: String, label: String)] = [
        ("openai_whisper-base.en",         "Base · English-only (~140 MB, fastest)"),
        ("openai_whisper-small.en",        "Small · English-only (~480 MB)"),
        ("openai_whisper-large-v3-turbo",  "Large Turbo · multilingual (~800 MB, recommended)"),
        ("openai_whisper-large-v3",        "Large v3 · multilingual (~1.5 GB, best accuracy)")
    ]
    static let defaultModelId = "openai_whisper-large-v3-turbo"

    private var kit: WhisperKit?
    private let modelId: String
    private let language: String?

    init(modelId: String = WhisperKitTranscriptionService.defaultModelId, language: String? = nil) {
        self.modelId = modelId
        self.language = language
    }

    // Call once at startup (or lazily on first transcription) to download + warm the model.
    func loadModel() async throws {
        guard kit == nil else { return }
        os_log(.info, log: log, "Loading WhisperKit model: %{public}@", modelId)
        kit = try await WhisperKit(model: modelId, verbose: false)
        os_log(.info, log: log, "WhisperKit model ready")
    }

    // Main entry point — same surface as the old TranscriptionService.
    func transcribe(fileURL: URL) async throws -> String {
        if kit == nil { try await loadModel() }
        guard let wk = kit else { throw WhisperKitError.notLoaded }

        var options = DecodingOptions()
        if let lang = language, !lang.isEmpty { options.language = lang }

        let results = try await wk.transcribe(audioPath: fileURL.path, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        os_log(.info, log: log, "Transcribed %{public}d chars", text.count)
        return text
    }
}

enum WhisperKitError: LocalizedError {
    case notLoaded
    var errorDescription: String? { "WhisperKit model not loaded" }
}
