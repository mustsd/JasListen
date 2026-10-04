import SwiftData
import SwiftUI

struct PlayerDetailView: View {
    @Environment(\.modelContext) private var context
    @ObservedObject var playback: AudioPlaybackController
    let lesson: Lesson

    @State private var pointA: TimeInterval?
    @State private var pointB: TimeInterval?
    @State private var loopMessage = "Set a start and end point to repeat a passage."
    @State private var lastPersistedBucket = -1

    init(lesson: Lesson, playback: AudioPlaybackController) {
        self.lesson = lesson
        self.playback = playback
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                titleBlock
                playerCard
                Text("Audio is stored on this device. Export a backup to move lessons between your Mac and iPhone.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 28)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.97, green: 0.97, blue: 0.94))
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
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("NOW LISTENING")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.7)
                .foregroundStyle(Color(red: 0.52, green: 0.59, blue: 0.53))
            Text(lesson.title)
                .font(.system(size: 31, weight: .semibold, design: .rounded))
                .tracking(-1.0)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Text("\(formatDuration(playback.duration > 0 ? playback.duration : lesson.duration)) · Local audio")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playerCard: some View {
        VStack(spacing: 21) {
            sessionHeader
            waveformArt
            progressSlider
            transportControls
            speedControl
            Divider()
            loopSection
        }
        .padding(23)
        .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(Color.black.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 18, y: 8)
        .onAppear { loadLoopState() }
    }

    private var sessionHeader: some View {
        HStack {
            Label("LISTENING SESSION", systemImage: "waveform")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.15)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatDuration(playback.duration))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var waveformArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.91, green: 0.93, blue: 0.86))
            Circle()
                .stroke(Color(red: 0.48, green: 0.59, blue: 0.44).opacity(0.2), lineWidth: 1)
                .frame(width: 174, height: 174)
            Ellipse()
                .stroke(Color(red: 0.70, green: 0.76, blue: 0.58).opacity(0.45), lineWidth: 1)
                .frame(width: 290, height: 100)
                .rotationEffect(.degrees(-15))
            HStack(spacing: 4) {
                ForEach([14.0, 22, 31, 18, 39, 26, 17, 33, 43, 20, 29, 16, 37, 23, 15, 32], id: \.self) { height in
                    Capsule()
                        .fill(Color(red: 0.40, green: 0.53, blue: 0.39))
                        .frame(width: 3, height: height)
                }
            }
            Text("s.")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.25, green: 0.41, blue: 0.32))
                .offset(y: -35)
        }
        .frame(height: 150)
        .accessibilityHidden(true)
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
        HStack(spacing: 20) {
            Button { playback.seek(to: max(0, playback.currentTime - 10)) } label: {
                Image(systemName: "gobackward.10").font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back 10 seconds")

            Button { playback.isPlaying ? playback.pause() : playback.play() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 58, height: 58)
                    .background(Color(red: 0.15, green: 0.39, blue: 0.32), in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Button { playback.seek(to: min(playback.duration, playback.currentTime + 10)) } label: {
                Image(systemName: "goforward.10").font(.system(size: 22))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Forward 10 seconds")
        }
        .foregroundStyle(Color(red: 0.37, green: 0.48, blue: 0.41))
        .padding(.vertical, 1)
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

    private var loopSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: "repeat")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(red: 0.37, green: 0.49, blue: 0.34))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stay with this part").font(.system(size: 13, weight: .semibold))
                    Text("Set two points, then repeat the passage.")
                        .font(.system(size: 10))
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
                Text(value.map(formatDuration) ?? (label == "A" ? "Set start" : "Set end"))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 36)
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
