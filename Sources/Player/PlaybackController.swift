import AVFoundation

enum PlaybackState {
    case idle
    case loading
    case ready
    case playing
    case paused
    case buffering
    case ended
    case failed(String)
}

/// Owns one AVPlayer and rejects callbacks from replaced items or earlier generations.
final class PlaybackController: NSObject {
    let player = AVPlayer()
    var onStateChange: ((PlaybackState) -> Void)?
    var onProgress: ((Double, Double) -> Void)?
    var onNaturalEnd: (() -> Void)?

    private(set) var generation = 0
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var periodicObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var restoredGeneration = -1
    private var preferredRate: Float = 1

    var currentTime: Double {
        let value = player.currentTime().seconds
        return value.isFinite ? max(0, value) : 0
    }

    var duration: Double {
        let value = player.currentItem?.duration.seconds ?? 0
        return value.isFinite && value > 0 ? value : 0
    }

    var isPlaying: Bool { player.timeControlStatus == .playing }
    var rate: Float { player.rate }

    func load(url: URL, resumeAt: Double, rate: Float, automaticallyPlay: Bool = true) {
        generation += 1
        let currentGeneration = generation
        preferredRate = max(0.5, rate)
        restoredGeneration = -1
        removeItemObservers()
        player.currentItem?.cancelPendingSeeks()
        player.pause()

        let item = AVPlayerItem(url: url)
        item.automaticallyPreservesTimeOffsetFromLive = false
        onStateChange?(.loading)
        player.replaceCurrentItem(with: item)
        observe(item: item, generation: currentGeneration, resumeAt: resumeAt, automaticallyPlay: automaticallyPlay)
    }

    func play() {
        guard player.currentItem != nil else { return }
        player.rate = preferredRate
    }

    func pause() { player.pause() }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func setRate(_ value: Float) {
        preferredRate = value
        if isPlaying { player.rate = value }
    }

    func seek(to seconds: Double, completion: ((Bool) -> Void)? = nil) {
        guard let item = player.currentItem else {
            completion?(false)
            return
        }
        let target = max(0, seconds)
        let time = CMTime(seconds: target, preferredTimescale: 600)
        guard time.isNumeric else {
            completion?(false)
            return
        }
        let currentGeneration = generation
        item.cancelPendingSeeks()
        item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] finished in
            DispatchQueue.main.async {
                guard let self, let item, self.isCurrent(item, generation: currentGeneration) else {
                    completion?(false)
                    return
                }
                completion?(finished)
            }
        }
    }

    func stop() {
        generation += 1
        removeItemObservers()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        player.replaceCurrentItem(with: nil)
        onStateChange?(.idle)
    }

    private func observe(item: AVPlayerItem, generation: Int, resumeAt: Double, automaticallyPlay: Bool) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] observed, _ in
            DispatchQueue.main.async {
                guard let self, let item, self.isCurrent(item, generation: generation) else { return }
                switch observed.status {
                case .readyToPlay:
                    self.onStateChange?(.ready)
                    if automaticallyPlay, self.restoredGeneration != generation {
                        self.restoredGeneration = generation
                        let duration = self.duration
                        if resumeAt > 1, duration <= 0 || resumeAt < duration - 1 {
                            self.seek(to: resumeAt) { _ in self.play() }
                        } else {
                            self.play()
                        }
                    }
                case .failed:
                    let message = observed.error?.localizedDescription ?? "视频加载失败，请检查网络和格式"
                    self.onStateChange?(.failed(message))
                default:
                    break
                }
            }
        }

        durationObservation = item.observe(\.duration, options: [.new]) { [weak self, weak item] observed, _ in
            DispatchQueue.main.async {
                guard let self, let item, self.isCurrent(item, generation: generation) else { return }
                self.onProgress?(self.currentTime, observed.duration.seconds)
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == generation, self.player.currentItem === item else { return }
                switch observed.timeControlStatus {
                case .playing: self.onStateChange?(.playing)
                case .waitingToPlayAtSpecifiedRate: self.onStateChange?(.buffering)
                case .paused:
                    if item.status == .readyToPlay { self.onStateChange?(.paused) }
                @unknown default: break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            guard let self, let item, self.isCurrent(item, generation: generation) else { return }
            self.player.pause()
            self.onStateChange?(.ended)
            self.onProgress?(self.duration, self.duration)
            self.onNaturalEnd?()
        }

        periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self, weak item] time in
            guard let self, let item, self.isCurrent(item, generation: generation) else { return }
            self.onProgress?(time.seconds, self.duration)
        }
    }

    private func isCurrent(_ item: AVPlayerItem, generation: Int) -> Bool {
        self.generation == generation && player.currentItem === item
    }

    private func removeItemObservers() {
        statusObservation?.invalidate()
        durationObservation?.invalidate()
        timeControlObservation?.invalidate()
        statusObservation = nil
        durationObservation = nil
        timeControlObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let periodicObserver { player.removeTimeObserver(periodicObserver) }
        periodicObserver = nil
    }

    deinit {
        statusObservation?.invalidate()
        durationObservation?.invalidate()
        timeControlObservation?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let periodicObserver { player.removeTimeObserver(periodicObserver) }
        player.currentItem?.cancelPendingSeeks()
    }
}
