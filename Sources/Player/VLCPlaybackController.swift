import UIKit
import MobileVLCKit

/// Uses libVLC to demux and decode formats AVPlayer does not handle, including FLV.
/// Every asynchronous callback is tied to both the load generation and VLCMedia identity.
final class VLCPlaybackController: NSObject, PlaybackEngine {
    let videoView = UIView()
    var onStateChange: ((PlaybackState) -> Void)?
    var onProgress: ((Double, Double) -> Void)?
    var onNaturalEnd: (() -> Void)?

    private let player = VLCMediaPlayer()
    private var generation = 0
    private var restoredGeneration = -1
    private var preferredRate: Float = 1
    private var pendingResumeAt = 0.0
    private var suppressEndAfterSeek = false

    override init() {
        super.init()
        videoView.backgroundColor = .black
        videoView.clipsToBounds = true
        player.delegate = self
        player.drawable = videoView
        player.scaleFactor = 0
    }

    var currentTime: Double {
        let t: VLCTime? = player.time
        return milliseconds(t?.intValue ?? 0)
    }

    var duration: Double {
        let len: VLCTime? = player.media?.length
        let value = milliseconds(len?.intValue ?? 0)
        return value > 0 ? value : 0
    }

    var isPlaying: Bool { player.isPlaying }
    var rate: Float { player.rate }

    func load(url: URL, resumeAt: Double, rate: Float, automaticallyPlay: Bool) {
        generation += 1
        restoredGeneration = -1
        preferredRate = max(0.5, rate)
        pendingResumeAt = resumeAt
        suppressEndAfterSeek = false
        player.stop()
        let media = VLCMedia(url: url)
        media.addOptions([
            "network-caching": 800,
            "file-caching": 800,
            "clock-jitter": 0,
            "clock-synchro": 0
        ])
        player.media = media
        onStateChange?(.loading)
        if automaticallyPlay { player.play() }
    }

    func play() {
        guard player.media != nil else { return }
        if player.state == .paused {
            player.pause() // VLCKit toggles out of pause and preserves the position.
        } else {
            player.play()
        }
        player.rate = preferredRate
    }

    func pause() { player.pause() }

    func setRate(_ value: Float) {
        preferredRate = max(0.5, value)
        if isPlaying { player.rate = preferredRate }
    }

    func seek(to seconds: Double, completion: ((Bool) -> Void)?) {
        guard let media = player.media else {
            completion?(false)
            return
        }
        let target = max(0, seconds)
        let currentGeneration = generation
        let currentDuration = duration
        suppressEndAfterSeek = currentDuration > 0 && target >= currentDuration - 0.5
        let milliseconds = Int32(min(target * 1000, Double(Int32.max)))
        player.time = VLCTime(int: milliseconds)
        DispatchQueue.main.async { [weak self, weak media] in
            guard let self, let media, self.isCurrent(media, generation: currentGeneration) else {
                completion?(false)
                return
            }
            self.onProgress?(self.currentTime, self.duration)
            completion?(true)
        }
    }

    func stop() {
        generation += 1
        restoredGeneration = -1
        pendingResumeAt = 0
        suppressEndAfterSeek = false
        player.stop()
        player.media = nil
        onStateChange?(.idle)
    }

    private func restoreIfNeeded(resumeAt: Double, generation: Int, media: VLCMedia) {
        guard restoredGeneration != generation else { return }
        restoredGeneration = generation
        let total = duration
        if resumeAt > 1, total <= 0 || resumeAt < total - 1 {
            seek(to: resumeAt) { [weak self] _ in
                guard let self, self.isCurrent(media, generation: generation) else { return }
                self.player.rate = self.preferredRate
            }
        }
        player.rate = preferredRate
    }

    private func isCurrent(_ media: VLCMedia, generation: Int) -> Bool {
        self.generation == generation && player.media === media
    }

    private func milliseconds(_ value: Int32) -> Double {
        max(0, Double(value) / 1000)
    }

    deinit {
        player.delegate = nil
        player.drawable = nil
        player.stop()
    }
}

extension VLCPlaybackController: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ notification: Notification!) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let media = self.player.media else { return }
            let generation = self.generation
            guard self.isCurrent(media, generation: generation) else { return }
            switch self.player.state {
            case .opening, .buffering:
                self.onStateChange?(.buffering)
            case .playing:
                self.restoreIfNeeded(resumeAt: self.pendingResumeAt, generation: generation, media: media)
                self.onStateChange?(.playing)
                self.onProgress?(self.currentTime, self.duration)
            case .paused:
                self.onStateChange?(.paused)
            case .ended:
                self.onStateChange?(.ended)
                self.onProgress?(self.duration, self.duration)
                if self.suppressEndAfterSeek {
                    self.suppressEndAfterSeek = false
                } else {
                    self.onNaturalEnd?()
                }
            case .error:
                self.onStateChange?(.failed("视频播放失败，请检查网络、Alist 地址或视频编码"))
            case .stopped:
                break
            default:
                break
            }
        }
    }

    func mediaPlayerTimeChanged(_ notification: Notification!) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player.media != nil else { return }
            self.onProgress?(self.currentTime, self.duration)
        }
    }
}
