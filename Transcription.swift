import AVFoundation
import Foundation

struct WhisperResult: Decodable {
    struct Segment: Decodable {
        struct Offset: Decodable { let from: Int }
        let offsets: Offset
        let text: String
    }
    let transcription: [Segment]
}

enum Transcription {
    static func run(meeting: Meeting, folder: URL, language: String = "auto") throws -> [Line] {
        try run(tracks: meeting.tracks, folder: folder, language: language)
    }

    static func run(tracks: [Track], folder: URL, language: String, preview: Bool = false) throws -> [Line] {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "whisper-cli"),
              let model = Bundle.main.url(forResource: "ggml-base-q5_1", withExtension: "bin") else {
            throw StillError("Still could not find its bundled speech model. Reinstall the app.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        var lines: [Line] = []
        for (index, track) in tracks.enumerated() {
            let wav = temporary.appendingPathComponent("track-\(index).wav")
            let result = temporary.appendingPathComponent("text-\(index)")
            let peak = try writeWave(from: folder.appendingPathComponent(track.file), to: wav)
            if preview, peak < 128 { continue }
            let process = Process()
            process.executableURL = helper
            process.currentDirectoryURL = temporary
            process.arguments = ["-m", model.path, "-f", wav.path, "-l", language,
                "-t", String(min(6, ProcessInfo.processInfo.activeProcessorCount)),
                "-oj", "-of", result.path, "-np"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw StillError("Transcription failed. The audio is still available in your library.")
            }
            let json = try Data(contentsOf: result.appendingPathExtension("json"))
            let segments = try JSONDecoder().decode(WhisperResult.self, from: json).transcription
            lines += segments.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return Line(time: track.offset + Double(segment.offsets.from) / 1000, source: track.name, text: text)
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    private static func writeWave(from source: URL, to destination: URL) throws -> Int {
        let input = try AVAudioFile(forReading: source)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw StillError("Still could not prepare this audio for transcription.")
        }
        if input.processingFormat.channelCount > 1 { converter.downmix = true }
        let output = try AVAudioFile(forWriting: destination, settings: format.settings,
            commonFormat: .pcmFormatInt16, interleaved: true)
        var readError: Error?
        var peak = 0
        while true {
            converted.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { frames, state in
                guard readError == nil, input.framePosition < input.length else {
                    state.pointee = .endOfStream
                    return nil
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: frames) else {
                    readError = StillError("Still could not allocate an audio buffer.")
                    state.pointee = .endOfStream
                    return nil
                }
                do { try input.read(into: buffer) } catch { readError = error }
                state.pointee = buffer.frameLength > 0 ? .haveData : .endOfStream
                return buffer.frameLength > 0 ? buffer : nil
            }
            if let error = readError ?? conversionError { throw error }
            if converted.frameLength > 0 {
                if let channel = converted.int16ChannelData?.pointee {
                    for index in 0..<Int(converted.frameLength) { peak = max(peak, abs(Int(channel[index]))) }
                }
                try output.write(from: converted)
            }
            if status == .endOfStream { return peak }
            if status != .haveData {
                throw StillError("Still could not convert the recording.")
            }
        }
    }
}

final class LiveTranscription: @unchecked Sendable {
    let folder: URL
    private let language: String
    private let receive: @Sendable (Result<[Line], Error>) -> Void
    private let queue = DispatchQueue(label: "local.still.live-transcript", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var stopped = false

    init(language: String, receive: @escaping @Sendable (Result<[Line], Error>) -> Void) throws {
        self.language = language
        self.receive = receive
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func submit(_ track: Track) {
        let file = folder.appendingPathComponent(track.file)
        lock.withLock {
            guard !stopped, pending < 3 else {
                try? FileManager.default.removeItem(at: file)
                return
            }
            pending += 1
            queue.async {
                defer {
                    try? FileManager.default.removeItem(at: file)
                    self.lock.withLock { self.pending -= 1 }
                }
                guard self.lock.withLock({ !self.stopped }) else { return }
                let result = Result {
                    try Transcription.run(tracks: [track], folder: self.folder, language: self.language, preview: true)
                }
                self.receive(result)
            }
        }
    }

    func report(_ error: Error) { receive(.failure(error)) }

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            queue.async { try? FileManager.default.removeItem(at: self.folder) }
        }
    }
}
