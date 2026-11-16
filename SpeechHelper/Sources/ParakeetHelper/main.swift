import FluidAudio
import Foundation

private struct Passage: Encodable {
    let time: Double
    let text: String
}

@main struct ParakeetHelper {
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 5 else { throw CocoaError(.fileReadInvalidFileName) }
            let models = try AsrModels.loadLocal(from: URL(fileURLWithPath: args[1]), version: .v3)
            let manager = AsrManager()
            try await manager.loadModels(models)
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(URL(fileURLWithPath: args[2]), decoderState: &state,
                                                     language: Language(rawValue: args[4]))
            var passages: [Passage] = []
            var words: [String] = []
            var start = 0.0
            for word in buildWordTimings(from: result.tokenTimings ?? []) {
                guard word.startTime.isFinite, word.startTime >= 0 else { continue }
                if words.isEmpty { start = word.startTime }
                words.append(word.word)
                if word.endTime - start >= 8 || word.word.last.map({ ".!?".contains($0) }) == true {
                    passages.append(Passage(time: start, text: words.joined(separator: " ")))
                    words = []
                }
            }
            if !words.isEmpty { passages.append(Passage(time: start, text: words.joined(separator: " "))) }
            if passages.isEmpty, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                passages.append(Passage(time: 0, text: result.text))
            }
            try JSONEncoder().encode(passages).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Parakeet: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
