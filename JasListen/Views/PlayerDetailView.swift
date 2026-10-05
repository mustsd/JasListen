import SwiftData
import SwiftUI

struct PlayerDetailView: View {
    @Environment(\.modelContext) private var context
    @ObservedObject var playback: AudioPlaybackController
    let lesson: Lesson
    let queue: [Lesson]
    let queueTitle: String
    let onSelectQueueLesson: (Lesson) -> Void

    /// Shared by the transport buttons and the macOS keys so both move by the
    /// same amount. The button symbols below are `gobackward.10` and
    /// `goforward.10`, which must match.
    private static let skipInterval: TimeInterval = 10

    @State private var pointA: TimeInterval?
    @State private var pointB: TimeInterval?
    @State private var loopMessage = "Set a start and end point to repeat a passage."
    @State private var lastPersistedBucket = -1
    @State private var isQueueExpanded = false

    init(
        lesson: Lesson,
        playback: AudioPlaybackController,
        queue: [Lesson],
        queueTitle: String,
        onSelectQueueLesson: @escaping (Lesson) -> Void
    ) {
        self.lesson = lesson
        self.playback = playback
        self.queue = queue
        self.queueTitle = queueTitle
        self.onSelectQueueLesson = onSelectQueueLesson
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: contentSpacing) {
                titleBlock
                playerCard
                if !queue.isEmpty { queueSection }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, contentPadding)
            .padding(.vertical, contentPadding)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .onChange(of: playback.currentTime) { _, value in
            let bucket = Int(value / 5)
            if bucket != lastPersistedBucket {
                lastPersistedBucket = bucket
                persistPosition()
            }
        }
        .onChange(of: playback.isPlaying) { _, isPlaying in
            if isPlaying {
                playback.markPlayed(lesson, context: context)
            } else {
                persistPosition()
            }
        }
        .onChange(of: playback.errorMessage) { _, error in
            if let error { loopMessage = error }
        }
        .onChange(of: lesson.title) { _, title in
            if playback.activeLessonID == lesson.id { playback.setTitle(title) }
        }
        // macOS: space plays or pauses, the arrow keys move back and forward.
        .macPlaybackKeys(
            togglePlayPause: { togglePlayPause() },
            skipBackward: { skip(by: -Self.skipInterval) },
            skipForward: { skip(by: Self.skipInterval) }
        )
    }

    private var contentSpacing: CGFloat {
        #if os(iOS)
        12
        #else
        24
        #endif
    }

    private var contentPadding: CGFloat {
        #if os(iOS)
        14
        #else
        28
        #endif
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PLAY QUEUE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(queueTitle)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(queue.count) tracks")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            LazyVStack(spacing: 2) {
                ForEach(visibleQueueItems, id: \.element.id) { index, queuedLesson in
                    queueRow(queuedLesson, index: index)
                }
            }

            if queue.count > visibleQueueItems.count || isQueueExpanded {
                Button(isQueueExpanded ? "Show fewer tracks" : "Show full queue") {
                    withAnimation(.easeInOut(duration: 0.2)) { isQueueExpanded.toggle() }
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.leading, 34)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleQueueItems: [(offset: Int, element: Lesson)] {
        let indexedQueue = Array(queue.enumerated())
        guard !isQueueExpanded, indexedQueue.count > 4 else { return indexedQueue }
        let currentIndex = queue.firstIndex(where: { $0.id == playback.activeLessonID }) ?? 0
        return Array(indexedQueue.dropFirst(currentIndex).prefix(4))
    }

    private func queueRow(_ queuedLesson: Lesson, index: Int) -> some View {
        let isCurrent = playback.activeLessonID == queuedLesson.id
        return Button {
            onSelectQueueLesson(queuedLesson)
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    .frame(width: 24, alignment: .trailing)
                Text(queuedLesson.title)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if isCurrent {
                    Image(systemName: playback.isPlaying ? "waveform" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(formatDuration(queuedLesson.duration))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                isCurrent ? Color.accentColor.opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(index + 1). \(queuedLesson.title), \(formatDuration(queuedLesson.duration))\(isCurrent ? ", now playing" : ", play")")
    }

    private func togglePlayPause() {
        playback.isPlaying ? playback.pause() : playback.play()
    }

    /// Moves through the lesson, clamped to its start and end.
    private func skip(by interval: TimeInterval) {
        playback.seek(to: min(max(0, playback.currentTime + interval), playback.duration))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("NOW LISTENING")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.7)
                .foregroundStyle(Color(red: 0.52, green: 0.59, blue: 0.53))
            Text(lesson.title)
                .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                .tracking(-1.0)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Text("\(formatDuration(playback.duration > 0 ? playback.duration : lesson.duration)) · Local audio")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleSize: CGFloat {
        #if os(iOS)
        23
        #else
        31
        #endif
    }

    private var playerCard: some View {
        VStack(spacing: cardSpacing) {
            waveformArt
            progressSlider
            transportControls
            speedControl
            volumeControl
            Divider()
            loopSection
        }
        .padding(cardPadding)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .onAppear { loadLoopState() }
    }

    private var cardSpacing: CGFloat {
        #if os(iOS)
        12
        #else
        21
        #endif
    }

    private var cardPadding: CGFloat {
        #if os(iOS)
        14
        #else
        23
        #endif
    }

    private var waveformArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.91, green: 0.93, blue: 0.86))
            Circle()
                .stroke(Color(red: 0.48, green: 0.59, blue: 0.44).opacity(0.2), lineWidth: 1)
                .frame(width: artRingSize, height: artRingSize)
            Ellipse()
                .stroke(Color(red: 0.70, green: 0.76, blue: 0.58).opacity(0.45), lineWidth: 1)
                .frame(width: artEllipseWidth, height: artEllipseHeight)
                .rotationEffect(.degrees(-15))
            HStack(spacing: 4) {
                ForEach([14.0, 22, 31, 18, 39, 26, 17, 33, 43, 20, 29, 16, 37, 23, 15, 32], id: \.self) { height in
                    Capsule()
                        .fill(Color(red: 0.40, green: 0.53, blue: 0.39))
                        .frame(width: 3, height: height)
                }
            }
            Text("s.")
                .font(.system(size: artMarkSize, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.25, green: 0.41, blue: 0.32))
                .offset(y: artMarkOffset)
        }
        .frame(height: artHeight)
        .accessibilityHidden(true)
    }

    private var artHeight: CGFloat {
        #if os(iOS)
        84
        #else
        150
        #endif
    }

    private var artRingSize: CGFloat {
        #if os(iOS)
        92
        #else
        174
        #endif
    }

    private var artEllipseWidth: CGFloat {
        #if os(iOS)
        150
        #else
        290
        #endif
    }

    private var artEllipseHeight: CGFloat {
        #if os(iOS)
        56
        #else
        100
        #endif
    }

    private var artMarkSize: CGFloat {
        #if os(iOS)
        20
        #else
        30
        #endif
    }

    private var artMarkOffset: CGFloat {
        #if os(iOS)
        -18
        #else
        -35
        #endif
    }

    private var seekBinding: Binding<Double> {
        Binding(
            get: { min(max(0, playback.currentTime), max(playback.duration, 0.01)) },
            set: { playback.seek(to: $0) }
        )
    }

    private var progressSlider: some View {
        VStack(spacing: 5) {
            Slider(value: seekBinding, in: 0...max(playback.duration, 0.01), onEditingChanged: sliderEditingChanged)
            HStack {
                Text(formatDuration(playback.currentTime))
                Spacer()
                Text(formatDuration(playback.duration))
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    private var transportControls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 16) {
                Button { skip(by: -Self.skipInterval) } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .help("Back \(Int(Self.skipInterval)) seconds (←)")
                .accessibilityLabel("Back \(Int(Self.skipInterval)) seconds")

                Button { togglePlayPause() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: playButtonSize, height: playButtonSize)
                        .background(Color(red: 0.15, green: 0.39, blue: 0.32), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Play or pause (space)")
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                Button { skip(by: Self.skipInterval) } label: {
                    Image(systemName: "goforward.10").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .help("Forward \(Int(Self.skipInterval)) seconds (→)")
                .accessibilityLabel("Forward \(Int(Self.skipInterval)) seconds")
            }
            #if os(macOS)
            Text("Space plays or pauses · ← → skip \(Int(Self.skipInterval)) seconds")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            #endif
        }
        .foregroundStyle(Color(red: 0.37, green: 0.48, blue: 0.41))
        .padding(.vertical, 1)
    }

    private var playButtonSize: CGFloat {
        #if os(iOS)
        48
        #else
        58
        #endif
    }

    private var speedBinding: Binding<Float> {
        Binding(
            get: { playback.playbackRate },
            set: { playback.setPlaybackRate($0) }
        )
    }

    private var speedControl: some View {
        HStack {
            Text("SPEED")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("Playback speed", selection: speedBinding) {
                Text("0.75×").tag(Float(0.75))
                Text("0.9×").tag(Float(0.9))
                Text("1×").tag(Float(1))
                Text("1.25×").tag(Float(1.25))
                Text("1.5×").tag(Float(1.5))
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 310)
            .accessibilityLabel("Playback speed; pitch is preserved")
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 10) {
            Image(systemName: playback.volume == 0 ? "speaker.slash" : "speaker.wave.1")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(
                get: { Double(playback.volume) },
                set: { playback.setVolume(Float($0)) }
            ), in: 0...1)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(playback.volume * 100)) percent")
            Image(systemName: "speaker.wave.3")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var loopSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "repeat")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(red: 0.37, green: 0.49, blue: 0.34))
                VStack(alignment: .leading, spacing: 3) {
                    Text("A–B repeat").font(.system(size: 12, weight: .semibold))
                    Text("Set two points to repeat a range.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 7) {
                pointButton(label: "A", value: pointA, set: setA)
                Text("—").font(.system(size: 11)).foregroundStyle(.secondary)
                pointButton(label: "B", value: pointB, set: setB)
                Spacer(minLength: 4)
                loopToggleButton
            }
            HStack {
                Text(loopMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(playback.errorMessage == nil ? Color.secondary : Color.red)
                Spacer()
                if playback.loop != nil {
                    Button("Clear") {
                        playback.clearLoop()
                        pointA = nil
                        pointB = nil
                        loopMessage = "Set a start and end point to repeat a passage."
                    }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var loopToggleButton: some View {
        Button {
            playback.toggleLoop()
            loopMessage = playback.loopEnabled
                ? "Repeating this range. Seek outside it to pause the loop."
                : "Loop stopped; the range is ready to repeat."
        } label: {
            Label("Loop", systemImage: "repeat")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(playback.loopEnabled ? Color(red: 0.15, green: 0.39, blue: 0.32) : Color(red: 0.85, green: 0.89, blue: 0.71))
        .foregroundStyle(playback.loopEnabled ? .white : Color(red: 0.30, green: 0.41, blue: 0.31))
        .disabled(playback.loop == nil)
        .accessibilityAddTraits(playback.loopEnabled ? .isSelected : [])
    }

    private func sliderEditingChanged(_ isEditing: Bool) {
        if !isEditing { persistPosition() }
    }

    private func pointButton(label: String, value: TimeInterval?, set: @escaping () -> Void) -> some View {
        Button(action: set) {
            HStack(spacing: 7) {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(label == "A" ? Color(red: 0.30, green: 0.48, blue: 0.32) : Color(red: 0.59, green: 0.38, blue: 0.29))
                    .frame(width: 19, height: 19)
                    .background(label == "A" ? Color(red: 0.9, green: 0.94, blue: 0.77) : Color(red: 0.97, green: 0.90, blue: 0.84), in: RoundedRectangle(cornerRadius: 6))
                Text(value.map(formatDuration) ?? "Set")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 34)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.09), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.map { "Set point \(label), currently \(formatDuration($0))" } ?? "Set point \(label)")
    }

    private func setA() {
        let position = playback.currentTime
        pointA = position
        if let pointB, position >= pointB - ABLoop.minimumDuration {
            self.pointB = nil
            playback.clearLoop()
        }
        loopMessage = "Start point A set at \(formatDuration(position))."
    }

    private func setB() {
        if pointA == nil { pointA = 0 }
        guard let pointA else { return }
        let end = playback.currentTime
        do {
            try playback.setLoop(start: pointA, end: end)
            pointB = end
            loopMessage = "Range set from \(formatDuration(pointA)) to \(formatDuration(end))."
        } catch {
            loopMessage = error.localizedDescription
        }
    }

    private func loadLoopState() {
        if playback.activeLessonID != lesson.id {
            do { try playback.load(lesson) }
            catch { loopMessage = error.localizedDescription }
        }
    }

    private func persistPosition() {
        guard playback.activeLessonID == lesson.id else { return }
        do { try playback.updateSavedPosition(lesson, context: context) }
        catch { loopMessage = "Could not save the playback position: \(error.localizedDescription)" }
    }

    private func formatDuration(_ value: Double) -> String {
        let seconds = max(0, Int(value))
        let hours = seconds / 3600
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, (seconds % 3600) / 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
