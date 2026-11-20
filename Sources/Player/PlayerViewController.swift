import UIKit
import AVFoundation
import MediaPlayer

final class PlayerViewController: UIViewController {
    private let course: Course
    private let playlist: [AlistFile]
    private var index: Int
    private let playback = PlaybackController()
    private let surface = PlayerSurfaceView()
    private let controls = UIView()
    private let topBar = UIStackView()
    private let bottomBar = UIStackView()
    private let titleLabel = UILabel.make(size: 16, weight: .semibold, color: .white)
    private let centerButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let errorStack = UIStackView()
    private let errorLabel = UILabel.make(size: 15, color: .white)
    private let retryButton = UIButton.action("重试")
    private let slider = UISlider()
    private let currentLabel = UILabel.make("00:00", size: 12, color: .white)
    private let durationLabel = UILabel.make("00:00", size: 12, color: .white)
    private let rateButton = UIButton(type: .system)
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let lockButton = UIButton(type: .system)
    private let unlockButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let gestureLabel = UILabel.make(size: 16, weight: .semibold, color: .white)
    private let gestureHUD = UIView()

    private var state: PlaybackState = .idle
    private var controlsVisible = true
    private var locked = false
    private var hideWorkItem: DispatchWorkItem?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var currentSource: PlaybackSource?
    private var usedTranscodeFallback = false
    private var lastProgressSave = Date.distantPast
    private var draggingSlider = false
    private var sliderWasPlaying = false
    private var normalRate: Float = 1
    private var temporaryRate: Float?
    private var temporaryRateBeforeLongPress: Float = 1
    private var speedTimer: Timer?
    private var panMode: PanMode = .none
    private var panStartTime = 0.0
    private var panWasPlaying = false
    private var panStartBrightness: CGFloat = 0
    private var panStartVolume: Float = 0
    private var previewTime: Double?
    private var volumeSlider: UISlider?

    private enum PanMode { case none, horizontal, brightness, volume }

    init(course: Course, playlist: [AlistFile], initialIndex: Int) {
        self.course = course
        self.playlist = playlist
        self.index = initialIndex
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { !controlsVisible }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var shouldAutorotate: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { !controlsVisible }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUI()
        buildGestures()
        configurePlayback()
        configureAudio()
        loadCurrent()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveCurrentProgress()
        loadTask?.cancel()
        playback.stop()
        speedTimer?.invalidate()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private var currentFile: AlistFile { playlist[index] }
    private var currentPath: String { currentFile.path }
    private var currentDuration: Double {
        max(playback.duration, AppEnvironment.shared.studyStore.state(for: course).state(for: currentPath).duration)
    }

    private func buildUI() {
        view.addSubview(surface)
        surface.pin(to: view)
        surface.playerLayer.player = playback.player
        surface.attachExternalView(playback.externalVideoView)

        controls.backgroundColor = UIColor.black.withAlphaComponent(0.16)
        view.addSubview(controls)
        controls.pin(to: view)

        let backButton = iconButton("chevron.left", action: #selector(close))
        doneButton.tintColor = .white
        doneButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        doneButton.addTarget(self, action: #selector(toggleDone), for: .touchUpInside)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 12
        [backButton, titleLabel, doneButton].forEach(topBar.addArrangedSubview)
        backButton.setContentHuggingPriority(.required, for: .horizontal)
        doneButton.setContentHuggingPriority(.required, for: .horizontal)
        controls.addSubview(topBar)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            topBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            topBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        configureCenterButton()
        controls.addSubview(centerButton)
        centerButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            centerButton.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            centerButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            centerButton.widthAnchor.constraint(equalToConstant: 74),
            centerButton.heightAnchor.constraint(equalToConstant: 74)
        ])

        spinner.color = .white
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)])

        buildErrorView()
        buildBottomBar()

        lockButton.setImage(UIImage(systemName: "lock.open"), for: .normal)
        lockButton.tintColor = .white
        lockButton.addTarget(self, action: #selector(lockControls), for: .touchUpInside)
        controls.addSubview(lockButton)
        lockButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            lockButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            lockButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            lockButton.widthAnchor.constraint(equalToConstant: 48),
            lockButton.heightAnchor.constraint(equalToConstant: 48)
        ])

        unlockButton.setImage(UIImage(systemName: "lock"), for: .normal)
        unlockButton.tintColor = .white
        unlockButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        unlockButton.layer.cornerRadius = 24
        unlockButton.addTarget(self, action: #selector(unlockControls), for: .touchUpInside)
        controls.addSubview(unlockButton)
        unlockButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            unlockButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            unlockButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            unlockButton.widthAnchor.constraint(equalToConstant: 48),
            unlockButton.heightAnchor.constraint(equalToConstant: 48)
        ])
        unlockButton.isHidden = true

        gestureHUD.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        gestureHUD.layer.cornerRadius = 12
        gestureHUD.alpha = 0
        gestureLabel.textAlignment = .center
        gestureHUD.addSubview(gestureLabel)
        gestureLabel.pin(to: gestureHUD, insets: UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18))
        view.addSubview(gestureHUD)
        gestureHUD.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            gestureHUD.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gestureHUD.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 74)
        ])
        applyControlVisibility()
    }

    private func configureCenterButton() {
        centerButton.tintColor = .white
        centerButton.backgroundColor = UIColor.black.withAlphaComponent(0.38)
        centerButton.layer.cornerRadius = 37
        centerButton.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)), for: .normal)
        centerButton.addTarget(self, action: #selector(centerAction), for: .touchUpInside)
    }

    private func buildErrorView() {
        errorStack.axis = .vertical
        errorStack.alignment = .center
        errorStack.spacing = 16
        errorLabel.textAlignment = .center
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        [errorLabel, retryButton].forEach(errorStack.addArrangedSubview)
        errorStack.isHidden = true
        view.addSubview(errorStack)
        errorStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            errorStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 30),
            errorStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -30)
        ])
    }

    private func buildBottomBar() {
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = AppColor.accent
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.35)
        slider.addTarget(self, action: #selector(sliderBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        currentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        rateButton.setTitle("1.0×", for: .normal)
        rateButton.setTitleColor(.white, for: .normal)
        rateButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        rateButton.addTarget(self, action: #selector(cycleRate), for: .touchUpInside)
        configureTransportButton(previousButton, name: "backward.end.fill", action: #selector(previous))
        configureTransportButton(nextButton, name: "forward.end.fill", action: #selector(nextChapter))

        let progressRow = UIStackView(arrangedSubviews: [currentLabel, slider, durationLabel])
        progressRow.axis = .horizontal
        progressRow.alignment = .center
        progressRow.spacing = 10
        let transportRow = UIStackView(arrangedSubviews: [rateButton, previousButton, nextButton])
        transportRow.axis = .horizontal
        transportRow.alignment = .center
        transportRow.distribution = .equalSpacing
        bottomBar.axis = .vertical
        bottomBar.spacing = 5
        [progressRow, transportRow].forEach(bottomBar.addArrangedSubview)
        controls.addSubview(bottomBar)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 22),
            bottomBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            transportRow.heightAnchor.constraint(equalToConstant: 40),
            rateButton.widthAnchor.constraint(equalToConstant: 70)
        ])
    }

    private func configureTransportButton(_ button: UIButton, name: String, action: Selector) {
        button.setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)), for: .normal)
        button.tintColor = .white
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 64).isActive = true
    }

    private func iconButton(_ name: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)), for: .normal)
        button.tintColor = .white
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    private func buildGestures() {
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTap))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.maximumNumberOfTouches = 1
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        long.minimumPressDuration = 0.5
        [single, double, pan, long].forEach {
            $0.delegate = self
            view.addGestureRecognizer($0)
        }
    }

    private func configurePlayback() {
        playback.onStateChange = { [weak self] state in self?.handle(state) }
        playback.onProgress = { [weak self] position, duration in self?.updateProgress(position: position, duration: duration) }
        playback.onNaturalEnd = { [weak self] in
            guard let self else { return }
            AppEnvironment.shared.studyStore.recordPlayback(
                course: self.course,
                path: self.currentPath,
                position: self.playback.duration,
                duration: self.playback.duration,
                naturallyFinished: true
            )
            self.updateDoneButton()
        }
    }

    private func configureAudio() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        NotificationCenter.default.addObserver(self, selector: #selector(saveProgressFromNotification), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
        let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 100, height: 40))
        view.addSubview(volumeView)
        volumeSlider = volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    private func loadCurrent() {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        currentSource = nil
        usedTranscodeFallback = false
        playback.stop()
        handle(.loading)
        errorStack.isHidden = true
        previewTime = nil
        titleLabel.text = currentFile.name
        slider.value = 0
        currentLabel.text = "00:00"
        durationLabel.text = "00:00"
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index < playlist.count - 1
        updateDoneButton()
        showControls()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let file = self.currentFile
                let path = self.currentPath
                let source = try await AppEnvironment.shared.api.playbackSource(for: file)
                guard !Task.isCancelled, generation == self.loadGeneration, path == self.currentPath else { return }
                self.currentSource = source
                let chapter = AppEnvironment.shared.studyStore.state(for: self.course).state(for: path)
                let resume = chapter.status == .done ? 0 : chapter.position
                self.surface.showsExternalPlayer = source.engine == .vlc
                self.playback.load(url: source.url, resumeAt: resume, rate: self.normalRate, engine: source.engine)
            } catch {
                guard !Task.isCancelled, generation == self.loadGeneration else { return }
                self.handle(.failed(error.localizedDescription))
            }
        }
    }

    private func handle(_ newState: PlaybackState) {
        if case .failed = newState, activateTranscodeFallback() { return }
        state = newState
        switch newState {
        case .idle:
            spinner.stopAnimating()
        case .loading:
            spinner.startAnimating()
            centerButton.isHidden = true
            errorStack.isHidden = true
        case .ready:
            spinner.stopAnimating()
            centerButton.isHidden = false
            errorStack.isHidden = true
        case .playing:
            spinner.stopAnimating()
            centerButton.isHidden = false
            centerButton.setImage(UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)), for: .normal)
            scheduleAutoHide()
        case .paused:
            spinner.stopAnimating()
            centerButton.isHidden = false
            centerButton.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)), for: .normal)
            saveCurrentProgress()
            showControls()
        case .buffering:
            spinner.startAnimating()
            showControls()
        case .ended:
            spinner.stopAnimating()
            centerButton.isHidden = false
            centerButton.setImage(UIImage(systemName: "arrow.counterclockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)), for: .normal)
            showControls()
        case .failed(let message):
            spinner.stopAnimating()
            centerButton.isHidden = true
            errorLabel.text = message
            errorStack.isHidden = false
            showControls()
        }
        applyControlVisibility()
    }

    private func activateTranscodeFallback() -> Bool {
        guard !usedTranscodeFallback,
              currentFile.fileExtension == "flv",
              let source = currentSource,
              source.engine == .vlc,
              let fallbackURL = source.fallbackURL else { return false }
        usedTranscodeFallback = true
        let resume = playback.currentTime
        surface.showsExternalPlayer = false
        showGestureHUD("直接播放失败，正在尝试 NAS 转封装")
        handle(.loading)
        playback.load(url: fallbackURL, resumeAt: resume, rate: normalRate, engine: .avFoundation)
        return true
    }

    private func updateProgress(position: Double, duration: Double) {
        guard position.isFinite else { return }
        let total = duration.isFinite && duration > 0 ? duration : currentDuration
        if !draggingSlider, panMode != .horizontal {
            currentLabel.text = TimeFormat.clock(position)
            durationLabel.text = TimeFormat.clock(total)
            slider.value = total > 0 ? Float((position / total).clamped(to: 0...1)) : 0
        }
        if playback.isPlaying, Date().timeIntervalSince(lastProgressSave) >= 5 {
            saveCurrentProgress()
        }
    }

    @objc private func saveProgressFromNotification() {
        saveCurrentProgress()
    }

    private func saveCurrentProgress() {
        AppEnvironment.shared.studyStore.recordPlayback(
            course: course,
            path: currentPath,
            position: playback.currentTime,
            duration: currentDuration,
            naturallyFinished: false
        )
        lastProgressSave = Date()
    }

    @objc private func close() {
        saveCurrentProgress()
        dismiss(animated: true)
    }

    @objc private func retry() { loadCurrent() }

    @objc private func centerAction() {
        if case .ended = state {
            playback.seek(to: 0) { [weak self] _ in self?.playback.play() }
        } else {
            playback.toggle()
        }
        showControls()
    }

    @objc private func previous() {
        guard index > 0 else { return }
        switchTo(index - 1)
    }

    @objc private func nextChapter() {
        guard index < playlist.count - 1 else { return }
        switchTo(index + 1)
    }

    private func switchTo(_ newIndex: Int) {
        saveCurrentProgress()
        index = newIndex
        loadCurrent()
    }

    @objc private func toggleDone() {
        AppEnvironment.shared.studyStore.toggleDone(course: course, path: currentPath)
        updateDoneButton()
        showControls()
    }

    private func updateDoneButton() {
        let chapter = AppEnvironment.shared.studyStore.state(for: course).state(for: currentPath)
        doneButton.setTitle(chapter.status == .done ? "已看 ✓" : "标为已看", for: .normal)
    }

    @objc private func cycleRate() {
        let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
        let nextIndex = (rates.firstIndex(of: normalRate).map { $0 + 1 } ?? 2) % rates.count
        normalRate = rates[nextIndex]
        playback.setRate(normalRate)
        rateButton.setTitle(displayRate(normalRate), for: .normal)
        showControls()
    }

    private func displayRate(_ rate: Float) -> String {
        rate == floor(rate) ? String(format: "%.0f×", rate) : String(format: "%.2g×", rate)
    }

    @objc private func singleTap() {
        if controlsVisible {
            controlsVisible = false
            applyControlVisibility()
        } else {
            showControls()
        }
    }

    @objc private func doubleTap() {
        guard !locked else { return }
        playback.toggle()
        showControls()
    }

    @objc private func lockControls() {
        locked = true
        controlsVisible = false
        applyControlVisibility()
    }

    @objc private func unlockControls() {
        locked = false
        showControls()
    }

    private func showControls() {
        hideWorkItem?.cancel()
        controlsVisible = true
        applyControlVisibility()
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        hideWorkItem?.cancel()
        guard controlsVisible, playback.isPlaying, !locked else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.controlsVisible = false
            self?.applyControlVisibility()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func applyControlVisibility() {
        let showRegularControls = controlsVisible && !locked
        topBar.isHidden = !showRegularControls
        bottomBar.isHidden = !showRegularControls
        lockButton.isHidden = !showRegularControls
        centerButton.isHidden = !showRegularControls || spinner.isAnimating || !errorStack.isHidden
        unlockButton.isHidden = !(controlsVisible && locked)
        controls.backgroundColor = controlsVisible && !locked ? UIColor.black.withAlphaComponent(0.16) : .clear
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    @objc private func sliderBegan() {
        draggingSlider = true
        sliderWasPlaying = playback.isPlaying
        playback.pause()
        hideWorkItem?.cancel()
    }

    @objc private func sliderChanged() {
        guard draggingSlider else { return }
        let target = Double(slider.value) * currentDuration
        previewTime = target
        currentLabel.text = TimeFormat.clock(target)
    }

    @objc private func sliderEnded() {
        guard draggingSlider else { return }
        draggingSlider = false
        let target = Double(slider.value) * currentDuration
        previewTime = nil
        playback.seek(to: target) { [weak self] _ in
            if self?.sliderWasPlaying == true { self?.playback.play() }
        }
        // Seeking to the end is not a natural completion and never marks the chapter done.
        saveCurrentProgress(position: target)
        showControls()
    }

    private func saveCurrentProgress(position: Double) {
        AppEnvironment.shared.studyStore.recordPlayback(
            course: course,
            path: currentPath,
            position: position,
            duration: currentDuration,
            naturallyFinished: false
        )
        lastProgressSave = Date()
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard !locked else { return }
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            panStartTime = playback.currentTime
            panWasPlaying = playback.isPlaying
            panStartBrightness = UIScreen.main.brightness
            panStartVolume = volumeSlider?.value ?? 0
            panMode = .none
        case .changed:
            if panMode == .none, abs(translation.x) > 12 || abs(translation.y) > 12 {
                if abs(translation.x) > abs(translation.y) {
                    panMode = .horizontal
                    playback.pause()
                } else {
                    let x = gesture.location(in: view).x
                    panMode = x < view.bounds.midX ? .brightness : .volume
                }
            }
            switch panMode {
            case .horizontal:
                let target = (panStartTime + Double(translation.x / view.bounds.width) * currentDuration).clamped(to: 0...max(currentDuration, 0))
                previewTime = target
                currentLabel.text = TimeFormat.clock(target)
                slider.value = currentDuration > 0 ? Float(target / currentDuration) : 0
                showGestureHUD("\(translation.x >= 0 ? "快进" : "快退")  \(TimeFormat.clock(target))")
            case .brightness:
                let value = (panStartBrightness - translation.y / view.bounds.height).clamped(to: 0...1)
                UIScreen.main.brightness = value
                showGestureHUD("亮度  \(Int(value * 100))%")
            case .volume:
                let value = (panStartVolume - Float(translation.y / view.bounds.height)).clamped(to: 0...1)
                volumeSlider?.setValue(value, animated: false)
                showGestureHUD("音量  \(Int(value * 100))%")
            case .none: break
            }
        case .ended, .cancelled:
            if panMode == .horizontal, let target = previewTime {
                playback.seek(to: target) { [weak self] _ in
                    if self?.panWasPlaying == true { self?.playback.play() }
                }
                saveCurrentProgress(position: target)
            }
            panMode = .none
            previewTime = nil
            hideGestureHUD()
            showControls()
        default: break
        }
    }

    @objc private func longPress(_ gesture: UILongPressGestureRecognizer) {
        guard !locked else { return }
        switch gesture.state {
        case .began:
            guard playback.isPlaying else { return }
            temporaryRateBeforeLongPress = normalRate
            temporaryRate = 2
            playback.setRate(2)
            showGestureHUD("临时 2× · 松手恢复")
            speedTimer?.invalidate()
            speedTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
                guard let self, let rate = self.temporaryRate else { return }
                let next = min(4, rate + 1)
                self.temporaryRate = next
                self.playback.setRate(next)
                self.showGestureHUD("临时 \(Int(next))× · 松手恢复")
            }
        case .ended, .cancelled, .failed:
            guard temporaryRate != nil else { return }
            speedTimer?.invalidate()
            speedTimer = nil
            temporaryRate = nil
            playback.setRate(temporaryRateBeforeLongPress)
            hideGestureHUD()
        default: break
        }
    }

    private func showGestureHUD(_ text: String) {
        hideWorkItem?.cancel()
        gestureLabel.text = text
        UIView.animate(withDuration: 0.15) { self.gestureHUD.alpha = 1 }
    }

    private func hideGestureHUD() {
        UIView.animate(withDuration: 0.2) { self.gestureHUD.alpha = 0 }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        playback.pause()
    }
}

extension PlayerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var current = touch.view
        while let view = current {
            if view is UIControl { return false }
            current = view.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}
