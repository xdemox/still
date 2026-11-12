import AppKit
import EventKit
import SwiftUI

private func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}
private let ink = adaptive(NSColor(srgbRed: 0.94, green: 0.93, blue: 0.90, alpha: 1), NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1))
private let surface = adaptive(NSColor(srgbRed: 0.90, green: 0.90, blue: 0.88, alpha: 1), NSColor(srgbRed: 0.15, green: 0.16, blue: 0.20, alpha: 1))
private let mint = adaptive(NSColor(srgbRed: 0.18, green: 0.34, blue: 0.46, alpha: 1), NSColor(srgbRed: 0.65, green: 0.77, blue: 0.83, alpha: 1))
private let paper = adaptive(NSColor(srgbRed: 0.16, green: 0.18, blue: 0.20, alpha: 1), NSColor(srgbRed: 0.94, green: 0.93, blue: 0.90, alpha: 1))
private let muted = adaptive(NSColor(srgbRed: 0.34, green: 0.36, blue: 0.38, alpha: 1), NSColor(srgbRed: 0.71, green: 0.72, blue: 0.74, alpha: 1))
private let rule = paper.opacity(0.18)
private let coral = adaptive(NSColor(srgbRed: 0.58, green: 0.27, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.92, green: 0.64, blue: 0.60, alpha: 1))
private let buttonText = adaptive(.white, NSColor(srgbRed: 0.10, green: 0.13, blue: 0.16, alpha: 1))

private struct StillSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? mint : paper.opacity(0.22))
                .frame(width: 36, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

@MainActor
final class EdgeState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    var resize: (() -> Void)?
    @Published var wide = false

    func setWide(_ value: Bool) {
        wide = value
        expanded = true
        resize?()
    }

    func setExpanded(_ value: Bool) {
        expanded = value
        if !value { pinned = false; wide = false }
        resize?()
    }
}

struct StillView: View {
    @AppStorage("StillAppearance") private var appearance = "system"
    @ObservedObject var model: Library
    @ObservedObject var edge: EdgeState
    @State private var libraryFilter = "All"
    @State private var selectedDate = Date()
    @State private var calendarMonth = Date()
    @State private var filterDate = false
    @State private var topicFilter = "All topics"
    @State private var speakerFilter = "All speakers"
    @State private var asking = false
    @State private var showSchedule = false
    @State private var scheduleDate = Date.now.addingTimeInterval(600)
    @StateObject private var agenda = Agenda()
    @State private var title = ""
    @State private var query = ""
    @State private var deleting: Meeting?
    @State private var removingAudio: Meeting?
    @State private var naming: Line?
    @State private var speakerName = ""
    @State private var correcting: Line?
    @State private var correctedText = ""
    @State private var detailMode = DetailMode.notes
    @State private var focusLine: String?
    private enum DetailMode: String, CaseIterable { case notes = "Notes", transcript = "Transcript" }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if edge.wide { wideLibrary }
            else if edge.expanded { panel } else { rail }
        }
        .preferredColorScheme(appearance == "day" ? .light : appearance == "night" ? .dark : nil)
        .foregroundStyle(paper)
        .confirmationDialog("Delete this meeting?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete meeting", role: .destructive) { if let deleting { model.delete(deleting) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This deletes the recording, transcript, and notes from this Mac.") }
        .confirmationDialog("Delete the audio?", isPresented: Binding(get: { removingAudio != nil }, set: { if !$0 { removingAudio = nil } }), titleVisibility: .visible) {
            Button("Delete audio", role: .destructive) { if let removingAudio { model.removeAudio(removingAudio) }; removingAudio = nil }
            Button("Cancel", role: .cancel) { removingAudio = nil }
        } message: { Text("The transcript, notes, and actions will stay. Audio playback will no longer be available.") }
        .alert("Correct transcript", isPresented: Binding(get: { correcting != nil }, set: { if !$0 { correcting = nil } })) {
            TextField("Passage", text: $correctedText)
            Button("Save") { if let correcting, let meeting = model.current { model.correct(correcting, text: correctedText, in: meeting) }; correcting = nil }
            Button("Cancel", role: .cancel) { correcting = nil }
        }
        .alert("Name this speaker", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $speakerName)
            Button("Save") {
                if let naming, let meeting = model.current { model.nameSpeaker(speakerName, line: naming, in: meeting) }
                naming = nil
            }
            Button("Cancel", role: .cancel) { naming = nil }
        } message: { Text("This name applies to the selected transcript passage.") }
    }

    private var rail: some View {
        VStack(spacing: 2) {
            railButton("calendar", "Agenda", .agenda)
            railButton(model.state == .recording ? "record.circle.fill" : "mic", "Record", .record)
            railButton("text.alignleft", "Recordings", .library)
            railButton("checkmark.circle", "Follow-ups", .followUps)
        }
        .padding(.vertical, 12)
        .frame(width: 56)
        .background(ink, in: UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private func railButton(_ symbol: String, _ label: String, _ page: Library.Page) -> some View {
        Button {
            model.page = page
            if page == .library { model.selected = nil }
            edge.setExpanded(true)
        } label: {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                .foregroundStyle(page == .record ? coral : page == .followUps ? Color.purple.opacity(0.75) : Color(red: 0.55, green: 0.64, blue: 0.76))
                .frame(width: 48, height: 44)
                .background(model.page == page && edge.expanded ? paper.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private var panel: some View {
        HStack(spacing: 14) {
        VStack(spacing: 0) {
            header
            if let notice = model.notice { banner(notice) }
            Group {
                switch model.page {
                case .record: recordPage
                case .library: libraryPage
                case .followUps: followUpsPage
                case .agenda: agendaPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                Text("Offline · Stored on this Mac")
                Spacer()
                Text("STILL")
                    .tracking(3)
                    .foregroundStyle(muted.opacity(0.8))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(mint.opacity(0.8))
            .padding(.horizontal, 22)
            .frame(height: 37)
            .overlay(alignment: .top) { Divider().overlay(rule) }
        }
        .frame(maxWidth: .infinity)
        .background(ink, in: RoundedRectangle(cornerRadius: 28))
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(rule).allowsHitTesting(false) }
        rail.frame(width: 56)
        }
    }

    private var themeMenu: some View {
        Menu {
            Picker("Appearance", selection: $appearance) {
                Text("Follow Mac").tag("system")
                Text("Day").tag("day")
                Text("Night").tag("night")
            }
        } label: {
            Image(systemName: "circle.lefthalf.filled").foregroundStyle(muted)
                .frame(width: 25, height: 25)
        }.menuStyle(.borderlessButton).fixedSize().help("Appearance").accessibilityLabel("Appearance")
    }

    private var header: some View {
        HStack(spacing: 11) {
            Text(model.page == .record ? "Capture" : model.page == .library ? "Recordings" : model.page == .followUps ? "Follow-ups" : "Agenda")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(muted)
            Spacer()
            if model.state == .recording {
                Circle().fill(coral).frame(width: 6, height: 6).accessibilityLabel("Recording")
            }
            themeMenu
            iconButton(edge.pinned ? "pin.fill" : "pin", edge.pinned ? "Unpin panel" : "Pin panel",
                       color: edge.pinned ? mint : muted) { edge.pinned.toggle() }
            iconButton("chevron.right", "Collapse panel") { edge.setExpanded(false) }
        }
        .padding(.horizontal, 22)
        .frame(height: 45)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            tab("Record", icon: "circle.dotted.circle", page: .record)
            tab("Library", icon: "text.alignleft", page: .library)
            tab("Follow-ups", icon: "checkmark.circle", page: .followUps)
            tab("Agenda", icon: "calendar", page: .agenda)
        }
        .padding(.horizontal, 22)
        .overlay(alignment: .bottom) { Rectangle().fill(rule).frame(height: 1) }
    }

    private func tab(_ title: String, icon: String, page: Library.Page) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { model.page = page }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(model.page == page ? mint : muted)
                .frame(maxWidth: .infinity, minHeight: 39)
                .overlay(alignment: .bottom) { if model.page == page { Capsule().fill(mint).frame(height: 2) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.page == page ? .isSelected : [])
    }

    private func banner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text(notice).frame(maxWidth: .infinity, alignment: .leading)
            iconButton("xmark", "Dismiss message", color: paper) { model.notice = nil }
        }
        .font(.system(size: 11))
        .foregroundStyle(paper)
        .padding(10)
        .background(surface)
        .padding(.horizontal, 22)
        .padding(.top, 12)
    }

    private var recordPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text(model.state == .recording ? "Recording" : "New recording")
                        .font(.system(size: 22, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Menu {
                        Picker("Transcript language", selection: $model.language) {
                            Text("Auto-detect").tag("auto")
                            Text("English").tag("en")
                            Text("French").tag("fr")
                            Text("German").tag("de")
                            Text("Italian").tag("it")
                            Text("Spanish").tag("es")
                            Text("Russian").tag("ru")
                        }
                    } label: { Image(systemName: "globe").foregroundStyle(muted) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Transcript language")
                    .accessibilityLabel("Transcript language")
                    .disabled(model.state != .idle)
                }
                TimelineView(.periodic(from: .now, by: model.state == .recording ? 0.12 : 10)) { _ in
                    HStack(spacing: 15) {
                        Text(clockText(model.elapsed))
                            .font(.system(size: 34, weight: .regular))
                            .foregroundStyle(model.state == .recording ? paper : muted)
                            .accessibilityLabel("Elapsed time \(clockText(model.elapsed))")
                        Spacer(minLength: 0)
                        meter(model.level)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 78)
                    .background(surface, in: RoundedRectangle(cornerRadius: 12))
                }
                if let active = model.active {
                    Text(active.title).font(.system(size: 13, weight: .medium))
                    if !active.marks.isEmpty {
                        Text("Marks  " + active.marks.map(clockText).joined(separator: " · "))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(mint)
                    }
                } else {
                    TextField("Meeting name (optional)", text: $title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(10)
                        .background(paper.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .disabled(model.state != .idle)
                }
                if model.state == .idle {
                VStack(spacing: 0) {
                    source("Microphone", detail: "Your voice and the room", icon: "mic", enabled: $model.mic)
                    Rectangle().fill(rule).frame(height: 1)
                    source("Mac audio", detail: "Calls and other sound from this Mac", icon: "speaker.wave.2", enabled: $model.mac)
                }
                .disabled(model.state != .idle)
                }
                if model.state == .idle {
                    HStack {
                        Text("Live transcript preview").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Toggle("Live transcript preview", isOn: $model.liveEnabled)
                            .labelsHidden().toggleStyle(StillSwitch())
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                HStack(spacing: 8) {
                    primary(
                        model.state == .recording ? "Stop & save" : model.state == .starting ? "Starting…" : model.state == .stopping ? "Saving…" : "Start recording",
                        icon: model.state == .recording ? "stop.fill" : "record.circle",
                        tint: model.state == .recording ? coral : mint
                    ) {
                        Task {
                            if model.state == .recording { await model.stop(); title = "" }
                            else { await model.start(title: title) }
                        }
                    }
                    .disabled(model.state == .starting || model.state == .stopping || (!model.mic && !model.mac))
                    if model.state == .recording {
                        Button { model.mark() } label: { Label("Mark", systemImage: "bookmark").padding(.horizontal, 5) }
                            .help("Mark this moment")
                    }
                }
                HStack {
                    if model.state == .idle {
                        Button { model.importAudio() } label: { Label("Import audio", systemImage: "square.and.arrow.down") }
                            .buttonStyle(.plain)
                            .foregroundStyle(mint)
                        Spacer()
                    }
                    Text(model.state == .recording ? "Add a mark to find this moment later." : "Tell everyone before you record.")
                        .foregroundStyle(muted)
                }
                .font(.system(size: 10))
                if model.state == .idle {
                    if let due = model.scheduledDate {
                        HStack {
                            Label("Scheduled for \(due.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                            Spacer()
                            Button("Cancel") { model.cancelSchedule() }.buttonStyle(.plain).foregroundStyle(mint)
                        }.font(.system(size: 11)).foregroundStyle(muted)
                    } else {
                        Button { showSchedule.toggle() } label: { Label("Schedule recording", systemImage: "clock") }
                            .buttonStyle(.plain).foregroundStyle(mint).font(.system(size: 11))
                        if showSchedule {
                            DatePicker("Start", selection: $scheduleDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                            Text("Keep Still open and your Mac awake. Recording starts with the selected audio sources.")
                                .font(.system(size: 10)).foregroundStyle(muted)
                            Button("Set schedule") { model.schedule(title: title, at: scheduleDate); showSchedule = false }
                        }
                    }
                }
                if model.state == .recording, model.liveEnabled { livePreview }
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
    }

    private var livePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(rule).frame(height: 1)
            Text("Live transcript").font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if model.liveIssue {
                Text("The preview had a problem. Still will transcribe the saved recording.")
                    .font(.system(size: 11)).foregroundStyle(coral)
            }
            if model.liveLines.isEmpty {
                Text("Waiting for speech. The preview updates about every ten seconds.")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
            ForEach(model.liveLines.suffix(6).reversed()) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text(clockText(line.time)).font(.system(size: 10, design: .monospaced)).foregroundStyle(mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.source).font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
                        Text(line.text).font(.system(size: 12))
                    }
                }
            }
        }
    }

    private func meter(_ level: Double) -> some View {
        let shape: [CGFloat] = [4, 8, 15, 7, 18, 27, 12, 22, 36, 19, 29, 13, 25, 16, 7, 12, 5]
        return HStack(spacing: 3) {
            ForEach(shape.indices, id: \.self) { i in
                Capsule()
                    .fill(mint.opacity(level > 0 ? 0.84 : 0.28))
                    .frame(width: 2, height: max(3, shape[i] * (level > 0 ? 0.35 + level : 0.47)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: level)
        .accessibilityHidden(true)
    }

    private func source(_ name: String, detail: String, icon: String, enabled: Binding<Bool>) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(mint).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(name, isOn: enabled).labelsHidden()
                .toggleStyle(StillSwitch())
                .frame(width: 42, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 49, alignment: .leading)
    }

    private var meetingCalendar: some View {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .month, for: calendarMonth)?.start ?? calendarMonth
        let days = calendar.range(of: .day, in: .month, for: start)?.count ?? 0
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(start.formatted(.dateTime.month(.wide))).font(.system(size: 17, weight: .semibold))
                    Text(start.formatted(.dateTime.year())).font(.system(size: 11)).foregroundStyle(muted)
                }
                Spacer()
                Button { if let date = calendar.date(byAdding: .month, value: -1, to: start) { calendarMonth = date } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold)).frame(width: 27, height: 27)
                        .background(paper.opacity(0.07), in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Previous month")
                Button { if let date = calendar.date(byAdding: .month, value: 1, to: start) { calendarMonth = date } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 27, height: 27)
                        .background(paper.opacity(0.07), in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Next month")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 5) {
                ForEach(0..<7, id: \.self) { index in
                    Text(symbols[(index + calendar.firstWeekday - 1) % 7])
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(muted).frame(maxWidth: .infinity).frame(height: 24)
                }
                ForEach(0..<(offset + days), id: \.self) { index in
                    if index < offset {
                        Color.clear.frame(height: 28).accessibilityHidden(true)
                    } else if let date = calendar.date(byAdding: .day, value: index - offset, to: start) {
                        let selected = filterDate && calendar.isDate(date, inSameDayAs: selectedDate)
                        let today = calendar.isDateInToday(date)
                        let hasMeeting = model.meetings.contains { calendar.isDate($0.date, inSameDayAs: date) }
                        Button { selectedDate = date; filterDate = true } label: {
                            VStack(spacing: 1) {
                                Text("\(index - offset + 1)").font(.system(size: 11, weight: selected || today ? .semibold : .regular))
                                Circle().fill(hasMeeting ? (selected ? buttonText : mint) : .clear).frame(width: 3, height: 3)
                            }
                            .frame(maxWidth: .infinity).frame(height: 28)
                            .foregroundStyle(selected ? buttonText : paper)
                            .background(selected ? mint : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(today && !selected ? mint.opacity(0.65) : .clear))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(date.formatted(date: .complete, time: .omitted) + (hasMeeting ? ", has meetings" : ""))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var wideLibrary: some View {
        let allLines = model.meetings.flatMap { $0.transcript ?? [] }
        let topics = TranscriptInsights.topics(allLines)
        let speakers = Array(Set(model.meetings.flatMap { meeting in (meeting.transcript ?? []).map { meeting.speaker(for: $0) } })).sorted()
        let results = model.meetings.filter { meeting in
            let textMatch = query.isEmpty || meeting.title.localizedCaseInsensitiveContains(query)
                || meeting.notes.localizedCaseInsensitiveContains(query) || matchingLine(in: meeting) != nil
            let dateMatch = !filterDate || Calendar.current.isDate(meeting.date, inSameDayAs: selectedDate)
            let typeMatch = libraryFilter == "All" ||
                (libraryFilter == "Notes" && !meeting.notes.isEmpty) ||
                (libraryFilter == "Actions" && meeting.reviewItems.contains { $0.kind == .action && $0.status != .dismissed }) ||
                (libraryFilter == "Transcript" && !(meeting.transcript ?? []).isEmpty)
            let topicMatch = topicFilter == "All topics" || (meeting.transcript ?? []).contains { TranscriptInsights.words($0.text).contains(topicFilter) }
            let speakerMatch = speakerFilter == "All speakers" || (meeting.transcript ?? []).contains { meeting.speaker(for: $0) == speakerFilter }
            return (asking || textMatch) && dateMatch && typeMatch && topicMatch && speakerMatch
        }
        return ZStack {
            ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Meetings", systemImage: "waveform").font(.system(size: 19, weight: .semibold))
                    Spacer()
                    Label("Stored on this Mac", systemImage: "externaldrive").font(.system(size: 11)).foregroundStyle(muted)
                    themeMenu
                    iconButton("arrow.down.right.and.arrow.up.left", "Return to compact view", color: mint) { edge.setWide(false) }
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(muted)
                    TextField("Search meetings, notes, and transcripts", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button("Ask") { asking = true }.buttonStyle(.plain).foregroundStyle(mint)
                        iconButton("xmark.circle.fill", "Clear search") { query = ""; asking = false }
                    }
                }
                .onChange(of: query) { _ in asking = false }
                .padding(13).background(paper.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 5) {
                    ForEach(["All", "Notes", "Actions", "Transcript"], id: \.self) { filter in
                        Button { libraryFilter = filter } label: {
                            Text(filter).font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 7)
                                .background(libraryFilter == filter ? paper.opacity(0.17) : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                    Menu(topicFilter) {
                        Button("All topics") { topicFilter = "All topics" }
                        ForEach(topics, id: \.self) { topic in Button(topic) { topicFilter = topic } }
                    }.menuStyle(.borderlessButton).fixedSize()
                    Menu(speakerFilter) {
                        Button("All speakers") { speakerFilter = "All speakers" }
                        ForEach(speakers, id: \.self) { speaker in Button(speaker) { speakerFilter = speaker } }
                    }.menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    Text("\(results.count) meetings").font(.system(size: 11)).foregroundStyle(muted)
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        meetingCalendar
                        Button { filterDate = false } label: {
                            HStack { Label("All dates", systemImage: "calendar"); Spacer(); if !filterDate { Image(systemName: "checkmark") } }
                        }.buttonStyle(.plain).foregroundStyle(mint).padding(10)
                            .background(paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        Spacer(minLength: 0)
                    }.padding(16).frame(width: 245).frame(maxHeight: .infinity)
                        .background(paper.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("Timeline").font(.system(size: 14, weight: .semibold)); Spacer(); Text("Newest first").font(.system(size: 11)).foregroundStyle(muted) }
                        Divider()
                        if asking {
                            let passages = results.flatMap { meeting in TranscriptInsights.matches(query, lines: meeting.transcript ?? []).map { (meeting, $0) } }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Related passages").font(.system(size: 13, weight: .semibold))
                                Text("Local keyword matches. Check the source for context.").font(.system(size: 11)).foregroundStyle(muted)
                                if passages.isEmpty { Text("No matching passages found.").font(.system(size: 12)).foregroundStyle(muted) }
                                ForEach(Array(passages.prefix(5).enumerated()), id: \.offset) { _, pair in
                                    Button { openMeeting(pair.0, at: pair.1) } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(pair.1.text).font(.system(size: 12)).lineLimit(3)
                                            Text("\(pair.0.title) · \(clockText(pair.1.time))").font(.system(size: 10)).foregroundStyle(mint)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                    }.buttonStyle(.plain)
                                }
                            }.padding(12).background(paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if results.isEmpty {
                            Text("No meetings found").foregroundStyle(muted).padding(.top, 20)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(results) { meeting in
                                        Button { openMeeting(meeting) } label: {
                                            HStack {
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text(meeting.title).font(.system(size: 14, weight: .semibold))
                                                    Text(meeting.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(muted)
                                                    if let line = matchingLine(in: meeting) { Text(line.text).font(.system(size: 11)).foregroundStyle(muted).lineLimit(2) }
                                                }
                                                Spacer()
                                                Text(clockText(meeting.duration)).font(.system(size: 11)).foregroundStyle(muted)
                                                Image(systemName: "arrow.up.right").foregroundStyle(muted)
                                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                                .background(paper.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(paper.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                }
            }.padding(24)
            if let meeting = model.current {
                Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { model.selected = nil }
                detail(meeting)
                    .frame(width: 620, height: 540)
                    .background(surface, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(rule))
                    .shadow(radius: 24)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(rule))
    }

    private var libraryPage: some View {
        Group {
            if let meeting = model.current { detail(meeting) }
            else {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Text("Recordings").font(.system(size: 24, design: .serif)).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button { model.selected = nil; edge.setWide(true) } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }.buttonStyle(.plain).foregroundStyle(mint)
                            .help("Expand Meetings").accessibilityLabel("Expand Meetings")
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(muted)
                        TextField("Search titles, notes, and transcripts", text: $query).textFieldStyle(.plain)
                        if !query.isEmpty { iconButton("xmark.circle.fill", "Clear search") { query = "" } }
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).frame(height: 36)
                    .background(paper.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    let results = model.meetings.filter { meeting in
                        query.isEmpty || meeting.title.localizedCaseInsensitiveContains(query) || meeting.notes.localizedCaseInsensitiveContains(query)
                            || (matchingLine(in: meeting) != nil)
                    }
                    if results.isEmpty {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: query.isEmpty ? "waveform" : "magnifyingglass").font(.system(size: 24)).foregroundStyle(mint)
                            Text(query.isEmpty ? "No recordings yet" : "No matches").font(.system(size: 15, weight: .medium))
                            Text(query.isEmpty ? "Record a meeting or import an audio file." : "Try a different search.")
                                .font(.system(size: 11)).foregroundStyle(muted)
                        }.frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(results) { meeting in
                                    Button { openMeeting(meeting) } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "waveform").foregroundStyle(mint).frame(width: 21)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(meeting.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                                Text(meeting.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(muted)
                                            }
                                            Spacer()
                                            Text(clockText(meeting.duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
                                        }.padding(.vertical, 11).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    if let line = matchingLine(in: meeting) {
                                        Button { openMeeting(meeting, at: line) } label: {
                                            Label("\(clockText(line.time))  \(line.text)", systemImage: "text.quote")
                                                .font(.system(size: 11)).foregroundStyle(mint)
                                                .lineLimit(2).padding(.bottom, 10)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }.buttonStyle(.plain)
                                    }
                                    Rectangle().fill(rule).frame(height: 1)
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }
                }.padding(22)
            }
        }
    }

    private func matchingLine(in meeting: Meeting) -> Line? {
        guard !query.isEmpty else { return nil }
        return meeting.transcript?.first {
            $0.text.localizedCaseInsensitiveContains(query) || meeting.speaker(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    private func openMeeting(_ meeting: Meeting, at line: Line? = nil) {
        focusLine = line?.id
        detailMode = line == nil ? .notes : .transcript
        model.selected = meeting.id
        model.page = .library
    }

    private var agendaPage: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Agenda").font(.system(size: 24, design: .serif)).accessibilityAddTraits(.isHeader)
            if !agenda.connected {
                Text(agenda.issue ?? "Read upcoming events from Calendar on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(muted)
                primary(agenda.requesting ? "Waiting for Calendar…" : "Connect Calendar", icon: "calendar", tint: mint) {
                    Task { await agenda.connect() }
                }.disabled(agenda.requesting)
            } else {
                TimelineView(.periodic(from: .now, by: 5)) { timeline in
                    let events = agenda.events.filter { $0.end > timeline.date }
                    if let next = events.first {
                        let seconds = next.start.timeIntervalSince(timeline.date)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(seconds <= 0 ? "IN PROGRESS" : "UP NEXT").tracking(2)
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(mint)
                            Text(next.title).font(.system(size: 19, design: .serif))
                            Text(seconds > 0 && seconds <= 3600 ? "Starts in \(clockText(seconds))" : next.start.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
                            Button { prepareRecording(next) } label: { Label("Set up recording", systemImage: "record.circle") }
                                .buttonStyle(.plain).foregroundStyle(mint).font(.system(size: 12, weight: .medium))
                                .disabled(model.state != .idle)
                        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                            .background(surface, in: RoundedRectangle(cornerRadius: 10))
                        if events.count > 1 {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(events.dropFirst()) { event in
                                        Button { prepareRecording(event) } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(event.title).font(.system(size: 12, weight: .semibold))
                                                Text(event.start.formatted(date: .abbreviated, time: .shortened))
                                                    .font(.system(size: 10)).foregroundStyle(muted)
                                            }.padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                        }.buttonStyle(.plain).disabled(model.state != .idle)
                                        Rectangle().fill(rule).frame(height: 1)
                                    }
                                }
                            }.scrollIndicators(.hidden)
                        }
                    } else {
                        Text("No timed events in the next seven days.").font(.system(size: 12)).foregroundStyle(muted)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .onAppear { agenda.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: DispatchQueue.main)) { _ in agenda.refresh() }
    }

    private func prepareRecording(_ event: Agenda.Event) {
        title = event.title
        model.page = .record
    }

    private var followUpsPage: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Follow-ups").font(.system(size: 24, design: .serif)).accessibilityAddTraits(.isHeader)
            if model.followUps.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 24)).foregroundStyle(mint)
                    Text("No actions yet").font(.system(size: 15, weight: .medium))
                    Text("Keep an action in a meeting to see it here.").font(.system(size: 11)).foregroundStyle(muted)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.followUps, id: \.id) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Button { openMeeting(entry.meeting, at: entry.item.line) } label: {
                                    Label(entry.meeting.title, systemImage: "arrow.up.right").font(.system(size: 11))
                                }.buttonStyle(.plain).foregroundStyle(mint)
                                reviewRow(entry.item, meeting: entry.meeting)
                            }
                            Rectangle().fill(rule).frame(height: 1)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }.padding(22)
    }

    private func detail(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { model.selected = nil } label: { Label("Recordings", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(mint)
                Spacer()
                Menu {
                    Button("Export as Markdown…") { model.export(meeting, markdown: true) }
                    Button("Export as text…") { model.export(meeting) }
                    if meeting.audioRemoved != true {
                        Menu("Export audio") {
                            ForEach(meeting.tracks) { track in
                                Button(track.name) { model.exportAudio(track, from: meeting) }
                            }
                        }
                        if meeting.transcript == nil { Button("Transcribe audio") { model.transcribe(meeting) }.disabled(model.transcribing.contains(meeting.id)) }
                        Button("Delete audio, keep notes…", role: .destructive) { removingAudio = meeting }.disabled(model.transcribing.contains(meeting.id))
                    }
                    Button("Delete meeting…", role: .destructive) { deleting = meeting }.disabled(model.transcribing.contains(meeting.id))
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(muted) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Meeting actions")
            }.font(.system(size: 11))
            TextField("Meeting name", text: Binding(get: { meeting.title }, set: { value in model.edit(meeting.id) { $0.title = value } }))
                .font(.system(size: 22, design: .serif)).textFieldStyle(.plain)
            Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11)).foregroundStyle(muted)
            if meeting.audioRemoved == true {
                Label("Audio deleted · Notes and transcript kept", systemImage: "doc.text")
                    .font(.system(size: 11)).foregroundStyle(muted)
            } else { TimelineView(.periodic(from: .now, by: model.playback == meeting.id ? 0.2 : 10)) { _ in
                let playing = model.playback == meeting.id
                HStack(spacing: 9) {
                    iconButton(playing ? "stop.fill" : "play.fill", playing ? "Stop playback" : "Play recording", color: mint) {
                        if playing { model.stopPlayback() } else { model.play(meeting) }
                    }.disabled(model.state != .idle)
                    Text(clockText(playing ? min(meeting.duration, model.playbackPosition) : 0)).monospacedDigit()
                    ProgressView(value: playing ? min(meeting.duration, model.playbackPosition) : 0, total: max(0.01, meeting.duration))
                        .tint(mint)
                    Text(clockText(meeting.duration)).monospacedDigit()
                }
                .font(.system(size: 11)).foregroundStyle(muted)
                .padding(.vertical, 4)
            } }
            if let lines = meeting.transcript, !lines.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SPEAKER TIMELINE").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(muted)
                    HStack(spacing: 2) {
                        ForEach(Array(lines.prefix(50).enumerated()), id: \.offset) { index, line in
                            Button { model.play(meeting, from: line.time) } label: {
                                Rectangle().fill(line.source == "Microphone" ? mint.opacity(0.7) : Color.purple.opacity(0.65))
                                    .frame(maxWidth: .infinity).frame(height: 8)
                            }.buttonStyle(.plain).help("\(meeting.speaker(for: line)) · \(clockText(line.time))")
                        }
                    }
                    Text("Colors show audio sources; named speakers appear on hover.").font(.system(size: 9)).foregroundStyle(muted)
                }
            }
            HStack(spacing: 2) {
                ForEach(DetailMode.allCases, id: \.self) { mode in
                    Button { detailMode = mode } label: {
                        Text(mode.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(detailMode == mode ? paper : muted)
                            .padding(.horizontal, 13).padding(.vertical, 7)
                            .background(detailMode == mode ? paper.opacity(0.12) : .clear, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
            .padding(3).background(paper.opacity(0.045), in: Capsule())
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 11) {
                        if detailMode == .notes { meetingNotes(meeting) }
                        else { transcript(meeting) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .task(id: focusLine) {
                    if let focusLine, detailMode == .transcript { scroll.scrollTo(focusLine, anchor: .center) }
                }
            }
        }.padding(.horizontal, 22).padding(.vertical, 15)
    }

    private func meetingNotes(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            if !meeting.marks.isEmpty {
                Text("Marks").font(.system(size: 12, weight: .semibold)).accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    HStack { ForEach(Array(meeting.marks.enumerated()), id: \.offset) { _, mark in
                        Button(clockText(mark)) { model.play(meeting, from: mark) }.buttonStyle(.bordered).tint(mint)
                    } }
                }.scrollIndicators(.hidden)
            }
            if let lines = meeting.transcript, !lines.isEmpty {
                let highlights = TranscriptInsights.summary(lines)
                if !highlights.isEmpty {
                    Text("AT A GLANCE").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(muted)
                    Text("Selected transcript passages").font(.system(size: 10)).foregroundStyle(muted)
                    ForEach(highlights) { line in
                        Button { model.play(meeting, from: line.time) } label: {
                            HStack(alignment: .top) {
                                Text("•  " + line.text).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Text(clockText(line.time)).font(.system(size: 10)).foregroundStyle(mint)
                            }.font(.system(size: 12))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("YOUR NOTES").font(.system(size: 9, weight: .semibold)).tracking(1.4)
                .foregroundStyle(muted).accessibilityAddTraits(.isHeader)
            TextEditor(text: Binding(get: { meeting.notes }, set: { value in model.edit(meeting.id) { $0.notes = value } }))
                .font(.system(size: 12)).scrollContentBackground(.hidden)
                .frame(minHeight: 73).accessibilityLabel("Meeting notes")
            let decisions = meeting.reviewItems.filter { $0.status != .dismissed && $0.kind == .decision }
            let actions = meeting.reviewItems.filter { $0.status != .dismissed && $0.kind == .action }
            if model.transcribing.contains(meeting.id) {
                Text("Suggestions appear after transcription.").font(.system(size: 11)).foregroundStyle(muted)
            } else if decisions.isEmpty && actions.isEmpty {
                Text("Use a passage’s menu in Transcript to add a decision or action.")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
            if !decisions.isEmpty {
                Text("DECISIONS").font(.system(size: 9, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(muted).padding(.top, 8).accessibilityAddTraits(.isHeader)
                ForEach(decisions) { item in reviewRow(item, meeting: meeting) }
            }
            if !actions.isEmpty {
                Text("ACTION ITEMS").font(.system(size: 9, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(muted).padding(.top, 8).accessibilityAddTraits(.isHeader)
                ForEach(actions) { item in reviewRow(item, meeting: meeting) }
            }
        }
    }

    private func reviewRow(_ item: ReviewItem, meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: item.kind == .action ? "checkmark.circle" : "checkmark.seal")
                Text(item.status == .suggested ? "Suggested \(item.kind.label.lowercased())" : item.kind.label)
                if item.status == .done { Text("· Done") }
                if let due = item.due { Text("· Due \(due.formatted(.dateTime.month(.abbreviated).day()))") }
                Spacer()
            }.font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
            Text(item.line.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 11) {
                Button { model.play(meeting, from: item.line.time) } label: {
                    Label(clockText(item.line.time), systemImage: "play.circle")
                }.buttonStyle(.plain).foregroundStyle(mint)
                Spacer()
                if item.status == .suggested {
                    Button("Dismiss") { model.review(item, in: meeting, status: .dismissed) }.buttonStyle(.plain).foregroundStyle(muted)
                    Button("Keep") { model.review(item, in: meeting, status: .kept) }.buttonStyle(.plain).foregroundStyle(mint)
                } else if item.kind == .action {
                    Menu {
                        Button(item.status == .done ? "Reopen" : "Mark done") {
                            model.review(item, in: meeting, status: item.status == .done ? .kept : .done)
                        }
                        Button("Due today") { setDue(0, item: item, meeting: meeting) }
                        Button("Due tomorrow") { setDue(1, item: item, meeting: meeting) }
                        Button("Due in one week") { setDue(7, item: item, meeting: meeting) }
                        if item.due != nil { Button("Clear due date") { setDue(nil, item: item, meeting: meeting) } }
                        Divider()
                        Button("Remove action") { model.review(item, in: meeting, status: .dismissed) }
                    } label: { Image(systemName: "ellipsis.circle").foregroundStyle(muted) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Action options")
                } else {
                    Button("Remove") { model.review(item, in: meeting, status: .dismissed) }
                        .buttonStyle(.plain).foregroundStyle(muted)
                }
            }.font(.system(size: 11, weight: .medium))
        }.padding(.vertical, 4)
    }

    private func setDue(_ days: Int?, item: ReviewItem, meeting: Meeting) {
        let today = Calendar.current.startOfDay(for: .now)
        let due = days.flatMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
        model.review(item, in: meeting, status: item.status, due: due, changeDue: true)
    }

    private func transcript(_ meeting: Meeting) -> some View {
        Group {
            if model.transcribing.contains(meeting.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing on this Mac…")
                }.font(.system(size: 11)).foregroundStyle(muted)
            } else if let lines = meeting.transcript, !lines.isEmpty {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 10) {
                            Button { model.play(meeting, from: line.time) } label: {
                                Text(clockText(line.time)).font(.system(size: 10, design: .monospaced)).foregroundStyle(mint)
                            }.buttonStyle(.plain).help("Play from \(clockText(line.time))")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(meeting.speaker(for: line)).font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
                                Text(line.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                            Menu {
                                Button("Correct text…") { correctedText = line.text; correcting = line }
                                Button("Name speaker…") {
                                    speakerName = meeting.speakerNames?[line.id] ?? ""
                                    naming = line
                                }
                                Button("Keep as a decision") { keep(.decision, line: line, meeting: meeting) }
                                Button("Keep as an action") { keep(.action, line: line, meeting: meeting) }
                            } label: { Image(systemName: "ellipsis").foregroundStyle(muted) }
                            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Transcript passage options")
                        }
                        .padding(6)
                        .background(line.id == focusLine ? mint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .id(line.id)
                    }
                }
            } else {
                Text(meeting.transcript == nil ? "Choose Transcribe audio in the meeting menu." : "Still found no speech.")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
        }
    }

    private func keep(_ kind: ReviewItem.Kind, line: Line, meeting: Meeting) {
        let new = ReviewItem(kind: kind, line: line)
        let item = meeting.review?.first { $0.id == new.id } ?? new
        model.review(item, in: meeting, status: item.status == .done ? .done : .kept)
    }

    private func iconButton(_ symbol: String, _ label: String, color: Color = muted, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
                .frame(width: 25, height: 25).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func primary(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(buttonText)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(tint, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .modifier(DimWhenDisabled())
    }
}

private struct DimWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) var isEnabled
    func body(content: Content) -> some View { content.opacity(isEnabled ? 1 : 0.48) }
}

final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StillDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = Library()
    private let edge = EdgeState()
    private var panel: EdgePanel!
    private var status: NSStatusItem!
    private var screen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = EdgePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.delegate = self
        panel.title = "Still"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: StillView(model: model, edge: edge))
        edge.resize = { [weak self] in self?.layout(animate: true) }
        screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Still")
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Still", action: #selector(showPanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Still", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
        layout(animate: false)
        panel.orderFrontRegardless()
        if !UserDefaults.standard.bool(forKey: "OpenedBefore") {
            UserDefaults.standard.set(true, forKey: "OpenedBefore")
            showPanel()
        }
        #if DEBUG
        if CommandLine.arguments.contains("--smoke-test") { Task { await model.smokeTest() } }
        #endif
    }

    @objc private func showPanel() {
        screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        edge.setExpanded(true)
    }

    private func layout(animate: Bool) {
        guard let screen = screen.flatMap({ NSScreen.screens.contains($0) ? $0 : nil }) ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame
        let width: CGFloat = edge.wide ? min(920, bounds.width) : edge.expanded ? min(460, bounds.width) : 56
        let height: CGFloat = edge.wide ? min(650, bounds.height - 24) : edge.expanded ? min(625, bounds.height - 24) : 166
        let frame = NSRect(x: screen.frame.maxX - width, y: bounds.midY - height / 2, width: width, height: height)
        panel.setFrame(frame, display: true, animate: animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if edge.expanded {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard edge.expanded, !edge.wide, !edge.pinned, !model.busy, panel.attachedSheet == nil else { return }
        edge.setExpanded(false)
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) { layout(animate: false) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.flushEdits()
        guard model.busy else { return .terminateNow }
        showPanel()
        model.notice = "Finish recording and transcription before quitting Still."
        return .terminateCancel
    }
}

@main
struct Still {
    static func main() {
        let app = NSApplication.shared
        let delegate = StillDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
