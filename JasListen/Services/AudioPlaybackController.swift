import AVFoundation
import Combine
import Foundation
import MediaPlayer
import SwiftData

struct ABLoop: Equatable {
    let start: TimeInterval
    let end: TimeInterval

    static let minimumDuration: TimeInterval = 0.25

    init(start: TimeInterval, end: TimeInterval, duration: TimeInterval) throws {
        guard start.isFinite, end.isFinite, duration.isFinite,
              start >= 0, end <= duration,
              end - start >= Self.minimumDuration else {
            throw LoopError.invalidRange
        }
        self.start = start
        self.end = end
    }
}

enum PlaybackQueue {
    static func nextID(after currentID: UUID, in lessonIDs: [UUID]) -> UUID? {
        guard let currentIndex = lessonIDs.firstIndex(of: currentID), !lessonIDs.isEmpty else { return nil }
        return lessonIDs[(currentIndex + 1) % lessonIDs.count]
    }
}

enum LoopError: LocalizedError {
    case invalidRange

    var errorDescription: String? {
        "Choose a range at least a quarter of a second long and within the audio."
    }
}

@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var loop: ABLoop?
    @Published private(set) var loopEnabled = false
    @Published private(set) var activeLessonID: UUID?
    @Published private(set) var completionCount = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var volume: Float = 1

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var activeTitle = "JasListen"
    private var resumeAfterInterruption = false
    private var playbackIntended = false

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        #if os(iOS)
        configureIOSAudioSession()
        #endif
        observePlayer()
        configureRemoteCommands()
        observeAudioSession()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        MPRemoteCommandCenter.shared().playCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().pauseCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.removeTarget(nil)
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
    }

    func load(_ lesson: Lesson, audioDirectory: URL? = nil) throws {
        let url = try AudioImportService.audioURL(for: lesson, audioDirectory: audioDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        playbackIntended = false
        player.pause()
        removeEndObserver()
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)
        registerEndObserver(for: item)
        activeLessonID = lesson.id
        activeTitle = lesson.title
        duration = lesson.duration
        currentTime = min(max(0, lesson.lastPosition), lesson.duration)
        errorMessage = nil
        loop = nil
        loopEnabled = false
        // Apply the saved position before the asynchronous duration load so
        // short clips and fast track switching resume immediately.
        player.seek(
            to: CMTime(seconds: currentTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        Task { [weak self, weak item] in
            guard let self, let item else { return }
            do {
                let loadedDuration = try await item.asset.load(.duration)
                guard self.player.currentItem === item else { return }
                let value = loadedDuration.seconds
                if value.isFinite, value > 0 { self.duration = value }
                await self.player.seek(to: CMTime(seconds: self.currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                self.updateNowPlayingInfo()
            } catch {
                guard self.player.currentItem === item else { return }
                self.errorMessage = "This audio could not be read. Try importing the file again."
            }
        }
        updateNowPlayingInfo()
    }

    func play(_ lesson: Lesson, context: ModelContext) {
        if activeLessonID != lesson.id {
            do {
                try load(lesson)
            } catch {
                errorMessage = "Could not open this lesson. \(error.localizedDescription)"
                return
            }
        }
        play()
        markPlayed(lesson, context: context)
    }

    /// Records a play only when playback actually starts, so a lesson is not
    /// marked as played just for being selected.
    func markPlayed(_ lesson: Lesson, context: ModelContext) {
        lesson.lastPlayedAt = .now
        try? context.save()
    }

    func play() {
        #if os(iOS)
        configureIOSAudioSession()
        #endif
        playbackIntended = true
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        playbackIntended = false
        player.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func stop() {
        playbackIntended = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeEndObserver()
        activeLessonID = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        loop = nil
        loopEnabled = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to position: TimeInterval) {
        guard duration > 0 else { return }
        let target = min(max(0, position), duration)
        if let loop, loopEnabled, !(loop.start...loop.end).contains(target) {
            loopEnabled = false
        }
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlayingInfo() }
        }
    }

    func setPlaybackRate(_ rate: Float) {
        let choices: [Float] = [0.75, 0.9, 1, 1.25, 1.5]
        playbackRate = choices.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 1
        if isPlaying { player.rate = playbackRate }
        updateNowPlayingInfo()
    }

    func setVolume(_ volume: Float) {
        self.volume = min(max(volume, 0), 1)
        player.volume = self.volume
    }

    func setLoop(start: TimeInterval, end: TimeInterval) throws {
        loop = try ABLoop(start: start, end: end, duration: duration)
        loopEnabled = false
    }

    func clearLoop() {
        loop = nil
        loopEnabled = false
    }

    func toggleLoop() {
        guard let loop else { return }
        loopEnabled.toggle()
        if loopEnabled {
            if currentTime < loop.start || currentTime >= loop.end { seek(to: loop.start) }
            play()
        }
    }

    func updateSavedPosition(_ lesson: Lesson, context: ModelContext) throws {
        guard activeLessonID == lesson.id else { return }
        lesson.lastPosition = min(max(0, currentTime), duration)
        if isPlaying { lesson.lastPlayedAt = .now }
        try context.save()
    }

    func clearError() { errorMessage = nil }

    func setTitle(_ title: String) {
        activeTitle = title
        updateNowPlayingInfo()
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite {
                    if let loop = self.loop, self.loopEnabled, seconds >= loop.end {
                        self.player.seek(to: CMTime(seconds: loop.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    self.currentTime = seconds
                }
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.isPlaying = status == .playing }
            .store(in: &cancellables)
        player.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard status == .failed else { return }
                self?.errorMessage = "This audio could not be played. Try importing the file again."
                self?.isPlaying = false
            }
            .store(in: &cancellables)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: activeTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0
        ]
        if #available(iOS 10.0, macOS 10.12.2, *) {
            info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    /// Repeats the A–B range when the item reaches the end and stops cleanly
    /// otherwise.
    private func registerEndObserver(for item: AVPlayerItem) {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item else { return }
                self.handlePlaybackEnded(for: item)
            }
        }
    }

    private func handlePlaybackEnded(for item: AVPlayerItem) {
        guard player.currentItem === item, playbackIntended else { return }
        if let loop, loopEnabled {
            player.seek(to: CMTime(seconds: loop.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
            updateNowPlayingInfo()
            return
        }
        // Seeking to the end can also post this notification, but a seek while
        // paused leaves playbackIntended false.
        playbackIntended = false
        player.pause()
        isPlaying = false
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] finished in
            guard finished else { return }
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                self.currentTime = 0
                self.updateNowPlayingInfo()
                self.completionCount += 1
            }
        }
    }

    private func observeAudioSession() {
        #if os(iOS)
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleInterruption(notification) }
        }
        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleRouteChange(notification) }
        }
        #endif
    }

    #if os(iOS)
    private func handleInterruption(_ notification: Notification) {
        guard let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawValue) else { return }
        switch type {
        case .began:
            resumeAfterInterruption = isPlaying
            pause()
        case .ended:
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            configureIOSAudioSession()
            if resumeAfterInterruption, options.contains(.shouldResume) {
                resumeAfterInterruption = false
                play()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue),
              reason == .oldDeviceUnavailable else { return }
        pause()
    }
    #endif

    #if os(iOS)
    private func configureIOSAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            errorMessage = "Could not start the system audio session: \(error.localizedDescription)"
        }
    }
    #endif
}
