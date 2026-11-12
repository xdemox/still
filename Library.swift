import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

func clockText(_ seconds: Double) -> String {
    let value = Int(max(0, seconds))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
    return String(format: "%02d:%02d", value / 60, value % 60)
}

@MainActor
final class Library: ObservableObject {
    enum Page { case record, library, followUps, agenda }
    enum State: Equatable { case idle, starting, recording, stopping }
    @Published var page: Page = .record
    @Published private(set) var state: State = .idle
    @Published var mic = true
    @Published var mac = true
    @Published var language = "auto"
    @Published var liveEnabled = true
    @Published private(set) var liveLines: [Line] = []
    @Published private(set) var liveIssue = false
    private var preview: LiveTranscription?
    @Published var selected: UUID?
    @Published var notice: String?
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var active: Meeting?
    @Published private(set) var transcribing: Set<UUID> = []
    @Published private(set) var playback: UUID?
    private var players: [AVAudioPlayer] = []
    private var playerStart: Double = 0
    private var playerPosition: Double = 0
    private var playbackTimer: Timer?
    @Published var scheduledDate: Date?
    @Published var scheduledTitle = ""
    private var scheduleTimer: Timer?

    func schedule(title: String, at date: Date) {
        guard date.timeIntervalSinceNow > 2 else { notice = "Choose a future start time."; return }
        scheduleTimer?.invalidate()
        scheduledDate = date
        scheduledTitle = title
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: date.timeIntervalSinceNow, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let due = self.scheduledDate else { return }
                self.scheduledDate = nil
                guard Date.now.timeIntervalSince(due) < 60, self.state == .idle else {
                    self.notice = "Scheduled recording did not start. Still was busy or the Mac was asleep."
                    return
                }
                self.page = .record
                await self.start(title: self.scheduledTitle)
            }
        }
    }

    func cancelSchedule() { scheduleTimer?.invalidate(); scheduleTimer = nil; scheduledDate = nil }
    private var pendingEdits: [UUID: Task<Void, Never>] = [:]
    private let recorder = Recorder()
    private let root = URL.applicationSupportDirectory.appendingPathComponent("Still/Meetings", isDirectory: true)

    var elapsed: Double { state == .recording ? recorder.elapsed : 0 }
    var level: Double { state == .recording ? recorder.level : 0 }
    var current: Meeting? { meetings.first { $0.id == selected } }
    var playbackPosition: Double { playerPosition + (playback == nil ? 0 : max(0, ProcessInfo.processInfo.systemUptime - playerStart)) }
    var busy: Bool { state != .idle || !transcribing.isEmpty }

    init() { load() }

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func load() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for dir in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("Meeting.json")),
                      var meeting = try? JSONDecoder().decode(Meeting.self, from: data),
                      meeting.id.uuidString == dir.lastPathComponent else { continue }
                if meeting.tracks.isEmpty {
                    for (name, file) in [("Microphone", "mic.m4a"), ("Microphone", "microphone.caf"), ("Mac audio", "mac.caf")] {
                        guard let audio = try? AVAudioFile(forReading: dir.appendingPathComponent(file)), audio.length > 0 else { continue }
                        meeting.tracks.append(Track(name: name, file: file, offset: 0,
                            duration: Double(audio.length) / audio.fileFormat.sampleRate))
                    }
                }
                if !meeting.tracks.isEmpty { meetings.append(meeting) }
            }
            meetings.sort { $0.date > $1.date }
        } catch { notice = "Still could not open the library. \(error.localizedDescription)" }
    }

    private func save(_ meeting: Meeting) throws {
        let encoder = JSONEncoder()
        try encoder.encode(meeting).write(to: folder(meeting.id).appendingPathComponent("Meeting.json"), options: .atomic)
    }

    func start(title: String) async {
        guard state == .idle, mic || mac else { return }
        state = .starting
        notice = nil
        liveLines = []
        liveIssue = false
        stopPlayback()
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = Meeting(id: UUID(), title: title.isEmpty ? "Untitled meeting" : title, date: .now)
        let directory = folder(meeting.id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try save(meeting)
            if liveEnabled {
                do {
                    preview = try LiveTranscription(language: language) { [weak self] result in
                        Task { @MainActor in
                            guard let self, self.active?.id == meeting.id else { return }
                            switch result {
                            case let .success(lines):
                                self.liveLines = Array((self.liveLines + lines).sorted { $0.time < $1.time }.suffix(40))
                            case .failure: self.liveIssue = true
                            }
                        }
                    }
                } catch { liveIssue = true }
            }
            try await recorder.start(in: directory, mic: mic, mac: mac, preview: preview) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.active?.id == meeting.id else { return }
                    await self.stop(issue: "Audio capture stopped. \(error.localizedDescription)")
                }
            }
            active = meeting
            state = .recording
        } catch {
            preview?.stop()
            preview = nil
            try? FileManager.default.removeItem(at: directory)
            notice = error.localizedDescription
            state = .idle
        }
    }

    func mark() {
        guard var meeting = active else { return }
        meeting.marks.append(elapsed)
        active = meeting
        do { try save(meeting) } catch { notice = error.localizedDescription }
    }

    func stop(issue: String? = nil) async {
        guard state == .recording, var meeting = active else { return }
        state = .stopping
        let (tracks, error) = await recorder.stop()
        preview?.stop()
        preview = nil
        active = nil
        state = .idle
        guard !tracks.isEmpty else {
            try? FileManager.default.removeItem(at: folder(meeting.id))
            notice = issue ?? "Still received no audio. Check your input and try again."
            return
        }
        meeting.tracks = tracks
        do { try save(meeting) } catch { notice = "Audio saved, but Still could not save the meeting details. \(error.localizedDescription)" }
        if let issue { notice = issue }
        else if let error { notice = "Still saved the audio it received. \(error.localizedDescription)" }
        else if mac && !tracks.contains(where: { $0.name == "Mac audio" }) { notice = "Still saved the microphone. It received no Mac audio." }
        meetings.insert(meeting, at: 0)
        selected = meeting.id
        page = .library
        transcribe(meeting)
    }

    func transcribe(_ meeting: Meeting) {
        guard transcribing.insert(meeting.id).inserted else { return }
        let dir = folder(meeting.id)
        let spokenLanguage = language
        Task {
            defer { transcribing.remove(meeting.id) }
            do {
                let lines = try await Task.detached(priority: .utility) {
                    try Transcription.run(meeting: meeting, folder: dir, language: spokenLanguage)
                }.value
                edit(meeting.id, flush: true) { $0.transcript = lines }
            } catch { notice = error.localizedDescription }
        }
    }

    func edit(_ id: UUID, flush: Bool = false, _ update: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        update(&meetings[index])
        pendingEdits[id]?.cancel()
        if flush { flushEdit(id) }
        else {
            pendingEdits[id] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { self?.flushEdit(id) }
            }
        }
    }

    private func flushEdit(_ id: UUID) {
        pendingEdits.removeValue(forKey: id)?.cancel()
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        do { try save(meeting) } catch { notice = "Still could not save your changes. \(error.localizedDescription)" }
    }

    struct FollowUp: Identifiable {
        var id: String { meeting.id.uuidString + item.id }
        let meeting: Meeting
        let item: ReviewItem
    }

    var followUps: [FollowUp] {
        meetings.flatMap { meeting in
            (meeting.review ?? []).filter { $0.kind == .action && ($0.status == .kept || $0.status == .done) }
                .map { FollowUp(meeting: meeting, item: $0) }
        }.sorted { first, second in
            if (first.item.status == .done) != (second.item.status == .done) { return first.item.status != .done }
            if first.item.due != second.item.due { return (first.item.due ?? .distantFuture) < (second.item.due ?? .distantFuture) }
            return first.meeting.date > second.meeting.date
        }
    }

    func review(_ item: ReviewItem, in meeting: Meeting, status: ReviewItem.Status, due: Date? = nil, changeDue: Bool = false) {
        var updated = item
        updated.status = status
        if changeDue { updated.due = due }
        edit(meeting.id, flush: true) { meeting in
            var items = meeting.review ?? []
            items.removeAll { $0.id == updated.id }
            items.append(updated)
            meeting.review = items
        }
    }

    func nameSpeaker(_ name: String, line: Line, in meeting: Meeting) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        edit(meeting.id, flush: true) { meeting in
            var names = meeting.speakerNames ?? [:]
            names[line.id] = name.isEmpty ? nil : name
            meeting.speakerNames = names
        }
    }

    func correct(_ line: Line, text: String, in meeting: Meeting) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != line.text else { return }
        let replacement = Line(time: line.time, source: line.source, text: text)
        edit(meeting.id, flush: true) { meeting in
            meeting.transcript = meeting.transcript?.map { $0.id == line.id ? replacement : $0 }
            if let name = meeting.speakerNames?.removeValue(forKey: line.id) {
                meeting.speakerNames?[replacement.id] = name
            }
            meeting.review = meeting.review?.map { item in
                guard item.line.id == line.id else { return item }
                return ReviewItem(kind: item.kind, line: replacement, status: item.status, due: item.due)
            }
        }
    }

    func removeAudio(_ meeting: Meeting) {
        guard !transcribing.contains(meeting.id), meeting.audioRemoved != true else { return }
        if playback == meeting.id { stopPlayback() }
        flushEdit(meeting.id)
        guard var updated = meetings.first(where: { $0.id == meeting.id }) else { return }
        updated.audioRemoved = true
        do {
            try save(updated)
            if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index] = updated }
            var failures = false
            for track in meeting.tracks {
                let url = folder(meeting.id).appendingPathComponent(track.file)
                if FileManager.default.fileExists(atPath: url.path) {
                    do { try FileManager.default.removeItem(at: url) } catch { failures = true }
                }
            }
            if failures { notice = "Some audio files could not be deleted. Check the meeting folder in Still's app container." }
        } catch { notice = "Still could not save this change. The audio was kept. \(error.localizedDescription)" }
    }

    func flushEdits() { for id in Array(pendingEdits.keys) { flushEdit(id) } }

    func delete(_ meeting: Meeting) {
        guard !transcribing.contains(meeting.id) else { return }
        if playback == meeting.id { stopPlayback() }
        do {
            try FileManager.default.removeItem(at: folder(meeting.id))
            pendingEdits.removeValue(forKey: meeting.id)?.cancel()
            meetings.removeAll { $0.id == meeting.id }
            if selected == meeting.id { selected = nil }
        } catch { notice = "Still could not delete the meeting. \(error.localizedDescription)" }
    }

    func play(_ meeting: Meeting, from time: Double = 0) {
        guard state == .idle, meeting.audioRemoved != true else { return }
        stopPlayback()
        do {
            let playable = try meeting.tracks.compactMap { track -> (AVAudioPlayer, Double)? in
                guard time < track.offset + track.duration else { return nil }
                let player = try AVAudioPlayer(contentsOf: folder(meeting.id).appendingPathComponent(track.file))
                player.currentTime = max(0, time - track.offset)
                guard player.prepareToPlay() else { throw StillError("Still could not prepare the recording for playback.") }
                return (player, max(0, track.offset - time))
            }
            guard !playable.isEmpty else { return }
            players = playable.map(\.0)
            let deviceStart = players[0].deviceCurrentTime + 0.15
            guard playable.map({ $0.0.play(atTime: deviceStart + $0.1) }).allSatisfy({ $0 }) else {
                throw StillError("Still could not play the recording.")
            }
            playerPosition = time
            playerStart = ProcessInfo.processInfo.systemUptime + 0.15
            playback = meeting.id
            playbackTimer = Timer.scheduledTimer(withTimeInterval: max(0.2, meeting.duration - time + 0.3), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.stopPlayback() }
            }
        } catch { stopPlayback(); notice = error.localizedDescription }
    }

    func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        for player in players { player.stop() }
        players = []
        playback = nil
    }

    func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { self.transcribe(try self.addAudio(url)) }
            catch { self.notice = "Still could not import this audio. \(error.localizedDescription)" }
        }
    }

    private func addAudio(_ source: URL) throws -> Meeting {
        let audio = try AVAudioFile(forReading: source)
        guard audio.length > 0 else { throw StillError("This audio file is empty.") }
        var meeting = Meeting(id: UUID(), title: source.deletingPathExtension().lastPathComponent, date: .now)
        let file = "imported." + source.pathExtension
        meeting.tracks = [Track(name: "Imported audio", file: file, offset: 0,
            duration: Double(audio.length) / audio.fileFormat.sampleRate)]
        let dir = folder(meeting.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(file))
            try save(meeting)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        meetings.insert(meeting, at: 0)
        selected = meeting.id
        page = .library
        return meeting
    }

    #if DEBUG
    func smokeTest() async {
        do {
            guard let sample = Bundle.main.url(forResource: "jfk", withExtension: "wav") else {
                throw StillError("Missing test audio.")
            }
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            guard socketFD >= 0 else { throw StillError("Could not create a test socket.") }
            defer { close(socketFD) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(9).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == -1, errno == EPERM || errno == EACCES else {
                throw StillError("Network connection was not blocked by the sandbox (errno \(errno)).")
            }
            let meeting = try addAudio(sample)
            let dir = folder(meeting.id)
            defer { delete(meeting) }
            let lines = try await Task.detached {
                try Transcription.run(meeting: meeting, folder: dir, language: "en")
            }.value
            guard lines.map(\.text).joined(separator: " ").localizedCaseInsensitiveContains("ask not") else {
                throw StillError("Transcript did not contain the expected phrase: \(lines.map(\.text)).")
            }
            edit(meeting.id, flush: true) { item in item.transcript = lines; item.notes = "Test note" }
            let saved = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: dir.appendingPathComponent("Meeting.json")))
            guard saved.transcript?.count == lines.count, saved.notes == "Test note", saved.duration > 8,
                  saved.review == nil, saved.speakerNames == nil else {
                throw StillError("The library did not save or load the legacy recording format.")
            }
            let decision = Line(time: 2, source: "Microphone", text: "We agreed to ship on Friday.")
            let action = Line(time: 4, source: "Mac audio", text: "I’ll follow up with the team.")
            edit(meeting.id, flush: true) { $0.transcript = [decision, action] }
            guard let updated = current, updated.reviewItems.map(\.kind) == [.decision, .action] else {
                throw StillError("The review did not find the decision and action.")
            }
            let item = updated.reviewItems[1]
            let due = Date.now.addingTimeInterval(3600)
            review(item, in: updated, status: .kept, due: due, changeDue: true)
            nameSpeaker("Sam", line: action, in: updated)
            let reviewed = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: dir.appendingPathComponent("Meeting.json")))
            guard followUps.contains(where: { $0.meeting.id == meeting.id && $0.item.due == due }),
                  reviewed.speaker(for: action) == "Sam", reviewed.reviewItems.count == 2 else {
                throw StillError("The review did not save the follow-up and speaker name.")
            }

            guard TranscriptInsights.matches("When did we ship Friday?", lines: [decision, action]).first?.id == decision.id,
                  !TranscriptInsights.summary([decision, action]).isEmpty,
                  TranscriptInsights.matches("zzzz", lines: [decision, action]).isEmpty else {
                throw StillError("Local transcript search failed.")
            }
            if let playable = current {
                play(playable)
                guard playback == playable.id, !players.isEmpty else { throw StillError("Audio playback did not start.") }
                stopPlayback()
            }

            let previewLines = try await Self.testPreview(sample, in: dir)
            guard previewLines.map(\.text).joined(separator: " ").localizedCaseInsensitiveContains("ask not") else {
                throw StillError("The live preview missed the expected phrase.")
            }
            guard let beforeCorrection = current else { throw StillError("The meeting was not selected.") }
            correct(action, text: "I will follow up tomorrow.", in: beforeCorrection)
            let corrected = Line(time: action.time, source: action.source, text: "I will follow up tomorrow.")
            guard let beforeRemoval = current, beforeRemoval.speaker(for: corrected) == "Sam",
                  beforeRemoval.review?.contains(where: { $0.line.id == corrected.id && $0.due == due }) == true else {
                throw StillError("Transcript correction did not preserve its speaker and action.")
            }
            removeAudio(beforeRemoval)
            let withoutAudio = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: dir.appendingPathComponent("Meeting.json")))
            guard withoutAudio.audioRemoved == true, withoutAudio.notes == "Test note", withoutAudio.duration > 8,
                  !FileManager.default.fileExists(atPath: dir.appendingPathComponent(meeting.tracks[0].file).path) else {
                throw StillError("Deleting audio did not preserve the meeting or remove the file.")
            }
            print("PASS: network blocked; import, transcription, preview, review, correction and audio removal verified.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        exit(0)
    }

    private static func testPreview(_ sample: URL, in folder: URL) async throws -> [Line] {
        let (results, continuation) = AsyncThrowingStream<[Line], Error>.makeStream()
        let preview = try LiveTranscription(language: "en") { result in
            switch result {
            case let .success(lines): continuation.yield(lines); continuation.finish()
            case let .failure(error): continuation.finish(throwing: error)
            }
        }
        defer { preview.stop() }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { continuation.finish(throwing: StillError("The live preview timed out.")) }
        }
        defer { timeout.cancel() }
        let writer = TrackWriter(name: "Test audio", url: folder.appendingPathComponent("preview-test.caf"),
            started: ProcessInfo.processInfo.systemUptime, preview: preview) { error in continuation.finish(throwing: error) }
        let audio = try AVAudioFile(forReading: sample)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else {
            throw StillError("Could not read the live preview sample.")
        }
        while audio.framePosition < audio.length {
            try audio.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            writer.append(buffer, timestamp: .nan)
        }
        let (track, error) = writer.finish()
        if let error { throw error }
        guard let track, track.duration > 10 else { throw StillError("The recording writer did not save all the audio.") }
        for try await lines in results { return lines }
        throw StillError("The live preview returned no result.")
    }
    #endif

    func exportAudio(_ track: Track, from meeting: Meeting) {
        let source = folder(meeting.id).appendingPathComponent(track.file)
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: source.pathExtension) { panel.allowedContentTypes = [type] }
        let title = meeting.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(title) – \(track.name).\(source.pathExtension)"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                        appropriateFor: url, create: true)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let staged = staging.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: source, to: staged)
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
                } else {
                    try FileManager.default.copyItem(at: source, to: url)
                }
            } catch { self?.notice = "Still could not export this audio. \(error.localizedDescription)" }
        }
    }

    func export(_ meeting: Meeting, markdown: Bool = false) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = markdown ? [UTType(filenameExtension: "md") ?? .plainText] : [.plainText]
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + (markdown ? ".md" : ".txt")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            var text = "\(markdown ? "# " : "")\(meeting.title)\n\(meeting.date.formatted(date: .long, time: .shortened))\n"
            if !meeting.notes.isEmpty { text += "\n\(markdown ? "## Notes" : "NOTES")\n\(meeting.notes)\n" }
            if !meeting.marks.isEmpty { text += "\n\(markdown ? "## Marks" : "MARKS")\n" + meeting.marks.map(clockText).joined(separator: " · ") + "\n" }
            let kept = (meeting.review ?? []).filter { $0.status == .kept || $0.status == .done }
            if !kept.isEmpty {
                text += "\n\(markdown ? "## Decisions and actions" : "DECISIONS AND ACTIONS")\n" + kept.map { item in
                    let due = item.due.map { " · Due " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
                    let done = item.status == .done ? " · Done" : ""
                    return "\(markdown ? "- " : "")[\(clockText(item.line.time))] \(item.kind.label)\(due)\(done)  \(item.line.text)"
                }.joined(separator: "\n") + "\n"
            }
            if let lines = meeting.transcript, !lines.isEmpty {
                text += "\n\(markdown ? "## Transcript" : "TRANSCRIPT")\n" + lines.map { "\(markdown ? "- " : "")[\(clockText($0.time))] \(meeting.speaker(for: $0))  \($0.text)" }.joined(separator: "\n") + "\n"
            }
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { self?.notice = error.localizedDescription }
        }
    }
}
