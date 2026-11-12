import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

struct Track: Codable, Identifiable {
    var id: String { file }
    let name: String
    let file: String
    let offset: Double
    let duration: Double
}

struct Line: Codable, Identifiable {
    var id: String { "\(source)-\(time)-\(text)" }
    let time: Double
    let source: String
    let text: String
}

struct Meeting: Codable, Identifiable {
    let id: UUID
    var title: String
    let date: Date
    var tracks: [Track] = []
    var marks: [Double] = []
    var transcript: [Line]? = nil
    var notes = ""
    var review: [ReviewItem]? = nil
    var speakerNames: [String: String]? = nil
    var audioRemoved: Bool? = nil

    func speaker(for line: Line) -> String { speakerNames?[line.id] ?? line.source }

    var duration: Double { tracks.map { $0.offset + $0.duration }.max() ?? 0 }
}

struct StillError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

final class TrackWriter {
    private let name: String
    private let url: URL
    private let started: Double
    private let preview: LiveTranscription?
    private let onFailure: (Error) -> Void
    private let queue = DispatchQueue(label: "local.still.track")
    private var file: AVAudioFile?
    private var firstTime: Double?
    private var offset: Double = 0
    private var frames: AVAudioFramePosition = 0
    private var rate: Double = 1
    private var failure: Error?
    private var level: Double = 0
    private var previewFile: AVAudioFile?
    private var previewStart: AVAudioFramePosition = 0
    private var previewFrames: AVAudioFramePosition = 0
    private var finished = false

    init(name: String, url: URL, started: Double, preview: LiveTranscription?, onFailure: @escaping (Error) -> Void) {
        self.name = name
        self.url = url
        self.started = started
        self.preview = preview
        self.onFailure = onFailure
    }

    func append(_ buffer: AVAudioPCMBuffer, timestamp: Double) {
        queue.sync {
            guard !finished, failure == nil, buffer.frameLength > 0 else { return }
            let clock = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            let validTime = timestamp.isFinite && abs(timestamp - clock) < 3
            do {
                if file == nil {
                    let received = ProcessInfo.processInfo.systemUptime - started
                    offset = max(0, received + (validTime ? timestamp - clock : 0))
                    firstTime = validTime ? timestamp : nil
                    rate = buffer.format.sampleRate
                    file = try open(url, format: buffer.format)
                }
                if validTime, let firstTime, timestamp >= firstTime {
                    let expected = AVAudioFramePosition(((timestamp - firstTime) * rate).rounded())
                    let gap = expected - frames
                    // Ignore small clock differences between the audio device and the host.
                    if gap > AVAudioFramePosition(rate * 0.05) {
                        try writeSilence(gap, format: buffer.format)
                    }
                }
                try write(buffer)
                if let channel = buffer.floatChannelData?.pointee {
                    let stride = buffer.stride
                    var peak: Float = 0
                    for index in Swift.stride(from: 0, to: Int(buffer.frameLength), by: 16) {
                        peak = max(peak, abs(channel[index * stride]))
                    }
                    level = Double(min(1, sqrt(peak) * 1.3))
                }
            } catch {
                failure = error
                onFailure(error)
            }
        }
    }

    func finish() -> (Track?, Error?) {
        queue.sync {
            finished = true
            file = nil
            if let previewFile {
                let url = previewFile.url
                self.previewFile = nil
                try? FileManager.default.removeItem(at: url)
            }
            let track = frames > 0 ? Track(name: name, file: url.lastPathComponent, offset: offset, duration: Double(frames) / rate) : nil
            return (track, failure)
        }
    }

    var meter: Double { queue.sync { level } }

    private func open(_ url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat,
                        interleaved: format.isInterleaved)
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        try file?.write(from: buffer)
        if let preview { writePreview(buffer, to: preview) }
        frames += AVAudioFramePosition(buffer.frameLength)
    }

    private func writePreview(_ buffer: AVAudioPCMBuffer, to preview: LiveTranscription) {
        do {
            if previewFile == nil {
                previewFile = try open(preview.folder.appendingPathComponent(UUID().uuidString + ".caf"), format: buffer.format)
                previewStart = frames
                previewFrames = 0
            }
            guard let url = previewFile?.url else { return }
            try previewFile?.write(from: buffer)
            previewFrames += AVAudioFramePosition(buffer.frameLength)
            if Double(previewFrames) / rate >= 10 {
                previewFile = nil
                let track = Track(name: name, file: url.lastPathComponent,
                    offset: offset + Double(previewStart) / rate, duration: Double(previewFrames) / rate)
                preview.submit(track)
            }
        } catch {
            if let url = previewFile?.url {
                previewFile = nil
                try? FileManager.default.removeItem(at: url)
            }
            preview.report(error)
        }
    }

    private func writeSilence(_ count: AVAudioFramePosition, format: AVAudioFormat) throws {
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(count, 16_384))) else { return }
        silence.frameLength = silence.frameCapacity
        for channel in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
        }
        var remaining = count
        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(remaining, AVAudioFramePosition(silence.frameCapacity)))
            try write(silence)
            remaining -= AVAudioFramePosition(silence.frameLength)
        }
    }
}

final class SystemCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "local.still.system-audio")
    private let writer: TrackWriter
    private let onFailure: (Error) -> Void
    private var stream: SCStream?

    init(writer: TrackWriter, onFailure: @escaping (Error) -> Void) {
        self.writer = writer
        self.onFailure = onFailure
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw StillError("macOS could not find a display for Mac audio capture.") }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let settings = SCStreamConfiguration()
        settings.capturesAudio = true
        settings.excludesCurrentProcessAudio = true
        settings.sampleRate = 48_000
        settings.channelCount = 2
        settings.width = 16
        settings.height = 16
        settings.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: settings, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async -> (Track?, Error?) {
        var stopError: Error?
        do { try await stream?.stopCapture() } catch { stopError = error }
        stream = nil
        let (track, error) = queue.sync { writer.finish() }
        return (track, error ?? stopError)
    }

    var meter: Double { writer.meter }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure(error) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sample.isValid, sample.numSamples > 0, let description = sample.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return }
        buffer.frameLength = AVAudioFrameCount(sample.numSamples)
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(sample.numSamples), into: buffer.mutableAudioBufferList)
        if copied == noErr { writer.append(buffer, timestamp: sample.presentationTimeStamp.seconds) }
    }
}

@MainActor
final class Recorder {
    private var microphone: AVAudioEngine?
    private var micWriter: TrackWriter?
    private var configurationObserver: NSObjectProtocol?
    private var system: SystemCapture?
    private var started: Double = 0

    func start(in folder: URL, mic: Bool, mac: Bool, preview: LiveTranscription?, onFailure: @escaping (Error) -> Void) async throws {
        if mic, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            throw StillError("Allow Microphone access for Still in System Settings → Privacy & Security.")
        }
        if mac, !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
            throw StillError("Allow Still in System Settings → Privacy & Security → Screen & System Audio Recording. Reopen Still if macOS asks.")
        }
        started = ProcessInfo.processInfo.systemUptime
        if mac {
            let writer = TrackWriter(name: "Mac audio", url: folder.appendingPathComponent("mac.caf"),
                started: started, preview: preview, onFailure: onFailure)
            let capture = SystemCapture(writer: writer, onFailure: onFailure)
            do { try await capture.start() } catch {
                throw StillError("Could not start Mac audio. \(error.localizedDescription)")
            }
            system = capture
        }
        do {
            if mic {
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.channelCount > 0, format.sampleRate > 0 else { throw StillError("Still could not find a microphone.") }
                let writer = TrackWriter(name: "Microphone", url: folder.appendingPathComponent("microphone.caf"),
                    started: started, preview: preview, onFailure: onFailure)
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
                    let seconds = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : .nan
                    writer.append(buffer, timestamp: seconds)
                }
                microphone = engine
                micWriter = writer
                try engine.start()
                configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                    object: engine, queue: nil) { _ in onFailure(StillError("The microphone changed while recording.")) }
            }
        } catch {
            _ = await stop()
            throw error
        }
    }

    var elapsed: Double { max(0, ProcessInfo.processInfo.systemUptime - started) }
    var level: Double { max(micWriter?.meter ?? 0, system?.meter ?? 0) }

    func stop() async -> ([Track], Error?) {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let microphone {
            microphone.stop()
            microphone.inputNode.removeTap(onBus: 0)
        }
        microphone = nil
        let (mic, micError) = micWriter?.finish() ?? (nil, nil)
        micWriter = nil
        let (mac, macError) = await system?.stop() ?? (nil, nil)
        system = nil
        return ([mic, mac].compactMap { $0 }, micError ?? macError)
    }
}
