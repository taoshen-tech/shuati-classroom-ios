import UIKit

final class CourseViewController: UIViewController {
    private struct Section {
        let title: String
        let videos: [AlistFile]
    }

    private let course: Course
    private let autoplayPath: String?
    private var didAutoplay = false
    private var videos: [AlistFile] = []
    private var sections: [Section] = []
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let progressLabel = UILabel.make(size: 30, weight: .bold)
    private let summaryLabel = UILabel.make(size: 14, color: .secondaryLabel)
    private let syncLabel = UILabel.make(size: 12, color: .secondaryLabel)
    private var observer: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?

    init(course: Course, autoplayPath: String? = nil) {
        self.course = course
        self.autoplayPath = autoplayPath
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = course.name
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "arrow.triangle.2.circlepath"), style: .plain, target: self, action: #selector(syncNow)),
            UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), style: .plain, target: self, action: #selector(refresh))
        ]
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "video")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        tableView.tableHeaderView = makeHeader()
        view.addSubview(tableView)
        tableView.pin(to: view)
        observer = NotificationCenter.default.addObserver(forName: StudyStore.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, note.userInfo?[StudyStore.coursePathUserInfoKey] as? String == self.course.path else { return }
            self.updateHeader()
            self.tableView.reloadData()
        }
        load(refresh: false)
    }

    deinit {
        loadTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateHeader()
        tableView.reloadData()
    }

    private func makeHeader() -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 174))
        let card = UIView()
        card.backgroundColor = AppColor.soft
        card.layer.cornerRadius = 20
        container.addSubview(card)
        card.pin(to: container, insets: UIEdgeInsets(top: 4, left: 4, bottom: 16, right: 4))
        let caption = UILabel.make("课程完成度", size: 12, weight: .semibold, color: .secondaryLabel)
        let stack = UIStackView(arrangedSubviews: [caption, progressLabel, summaryLabel, syncLabel])
        stack.axis = .vertical
        stack.spacing = 7
        card.addSubview(stack)
        stack.pin(to: card, insets: UIEdgeInsets(top: 18, left: 20, bottom: 16, right: 20))
        return container
    }

    private func updateHeader() {
        let state = AppEnvironment.shared.studyStore.state(for: course)
        progressLabel.text = state.percent.map { "\($0)%" } ?? "—"
        summaryLabel.text = state.hasScannedCatalog ? "已看 \(state.doneCount) 节，共 \(state.total) 节" : "正在建立课程目录"
        if let error = AppEnvironment.shared.studyStore.syncErrors[course.path] {
            syncLabel.text = "待同步 · \(error)"
            syncLabel.textColor = .systemRed
        } else if let date = AppEnvironment.shared.studyStore.lastSyncDates[course.path] {
            syncLabel.text = "已同步 · \(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short))"
            syncLabel.textColor = .secondaryLabel
        } else {
            syncLabel.text = "修改会保存在本机并自动同步"
            syncLabel.textColor = .secondaryLabel
        }
    }

    @objc private func refresh() { load(refresh: true) }

    private func load(refresh: Bool) {
        guard loadTask == nil else { return }
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tableView.refreshControl?.endRefreshing()
                self.loadTask = nil
            }
            do {
                let files = try await AppEnvironment.shared.api.scanVideos(course: self.course, refresh: refresh)
                guard !Task.isCancelled else { return }
                self.videos = files
                AppEnvironment.shared.studyStore.updateCatalog(course: self.course, paths: files.map(\.path))
                self.rebuildSections()
                try? await AppEnvironment.shared.studyStore.refreshFromRemote(course: self.course)
                self.updateHeader()
                self.tableView.reloadData()
                if !self.didAutoplay, let target = self.autoplayPath, let index = files.firstIndex(where: { $0.path == target }) {
                    self.didAutoplay = true
                    self.openPlayer(at: index)
                }
            } catch {
                if !Task.isCancelled { self.showError(error, title: "目录读取失败") }
            }
        }
    }

    private func rebuildSections() {
        let root = course.path.hasSuffix("/") ? String(course.path.dropLast()) : course.path
        var grouped: [String: [AlistFile]] = [:]
        for video in videos {
            var directory = (video.path as NSString).deletingLastPathComponent
            if directory == root { directory = "课程视频" }
            else if directory.hasPrefix(root + "/") { directory = String(directory.dropFirst(root.count + 1)) }
            grouped[directory, default: []].append(video)
        }
        sections = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map {
            Section(title: $0, videos: grouped[$0] ?? [])
        }
        tableView.backgroundView = videos.isEmpty ? emptyLabel("这个课程里还没有支持的视频") : nil
    }

    private func emptyLabel(_ text: String) -> UILabel {
        let label = UILabel.make(text, size: 15, color: .secondaryLabel)
        label.textAlignment = .center
        return label
    }

    private func video(at indexPath: IndexPath) -> AlistFile { sections[indexPath.section].videos[indexPath.row] }

    private func openPlayer(at index: Int) {
        let player = PlayerViewController(course: course, playlist: videos, initialIndex: index)
        player.modalPresentationStyle = .fullScreen
        present(player, animated: true)
    }

    @objc private func syncNow() {
        Task { @MainActor in
            do {
                try await AppEnvironment.shared.studyStore.flush(course: course)
                showMessage("这门课程的学习记录已完成同步。", title: "同步完成")
            } catch {
                showError(error, title: "同步失败，记录仍保存在本机")
            }
            updateHeader()
        }
    }

    private func toggleDone(at indexPath: IndexPath) {
        AppEnvironment.shared.studyStore.toggleDone(course: course, path: video(at: indexPath).path)
    }

    private func showPlanPicker(at indexPath: IndexPath) {
        let path = video(at: indexPath).path
        let current = AppEnvironment.shared.studyStore.state(for: course).state(for: path).planDate
        let picker = DatePlanViewController(current: current) { date in
            AppEnvironment.shared.studyStore.setPlanDate(date, course: self.course, path: path)
        }
        present(picker, animated: true)
    }
}

extension CourseViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].videos.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "video", for: indexPath)
        let video = video(at: indexPath)
        let state = AppEnvironment.shared.studyStore.state(for: course).state(for: video.path)
        var content = cell.defaultContentConfiguration()
        content.text = (video.name as NSString).deletingPathExtension
        content.textProperties.numberOfLines = 2
        var details = state.status.label
        if state.position > 0, state.status != .done { details += " · \(state.timeText)" }
        if let plan = state.planDate { details += " · \(TimeFormat.planLabel(plan))" }
        content.secondaryText = details
        content.secondaryTextProperties.numberOfLines = 2
        content.secondaryTextProperties.color = state.status == .done ? .systemGreen : .secondaryLabel
        content.image = UIImage(systemName: state.status == .done ? "checkmark.circle.fill" : "play.circle")
        content.imageProperties.tintColor = state.status == .done ? .systemGreen : AppColor.accent
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let index = videos.firstIndex(ofPath: video(at: indexPath).path) else { return }
        openPlayer(at: index)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let state = AppEnvironment.shared.studyStore.state(for: course).state(for: video(at: indexPath).path)
        let action = UIContextualAction(style: .normal, title: state.status == .done ? "标为未看" : "标为已看") { [weak self] _, _, completion in
            self?.toggleDone(at: indexPath)
            completion(true)
        }
        action.backgroundColor = state.status == .done ? .systemGray : .systemGreen
        return UISwipeActionsConfiguration(actions: [action])
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let action = UIContextualAction(style: .normal, title: "计划") { [weak self] _, _, completion in
            self?.showPlanPicker(at: indexPath)
            completion(true)
        }
        action.backgroundColor = AppColor.accent
        return UISwipeActionsConfiguration(actions: [action])
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let today = UIAction(title: "计划今天学习", image: UIImage(systemName: "sun.max")) { _ in
                AppEnvironment.shared.studyStore.setPlanDate(Date(), course: self.course, path: self.video(at: indexPath).path)
            }
            let tomorrow = UIAction(title: "计划明天学习", image: UIImage(systemName: "calendar")) { _ in
                let date = Calendar.current.date(byAdding: .day, value: 1, to: Date())
                AppEnvironment.shared.studyStore.setPlanDate(date, course: self.course, path: self.video(at: indexPath).path)
            }
            let choose = UIAction(title: "选择日期", image: UIImage(systemName: "calendar.badge.plus")) { _ in self.showPlanPicker(at: indexPath) }
            let clear = UIAction(title: "清除计划", image: UIImage(systemName: "calendar.badge.minus"), attributes: .destructive) { _ in
                AppEnvironment.shared.studyStore.setPlanDate(nil, course: self.course, path: self.video(at: indexPath).path)
            }
            return UIMenu(children: [today, tomorrow, choose, clear])
        }
    }
}

private extension Array where Element == AlistFile {
    func firstIndex(ofPath path: String) -> Int? { firstIndex { $0.path == path } }
}

final class DatePlanViewController: UIViewController {
    private let picker = UIDatePicker()
    private let onSave: (Date?) -> Void
    private let hasExistingPlan: Bool

    init(current: String?, onSave: @escaping (Date?) -> Void) {
        self.onSave = onSave
        self.hasExistingPlan = current != nil
        super.init(nibName: nil, bundle: nil)
        if let current {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            picker.date = formatter.date(from: current) ?? Date()
        }
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .inline
        picker.locale = Locale(identifier: "zh_CN")
        let titleLabel = UILabel.make("安排学习日期", size: 22, weight: .bold)
        let save = UIButton.action("保存计划")
        save.addTarget(self, action: #selector(savePlan), for: .touchUpInside)
        let clear = UIButton.action("清除计划", primary: false)
        clear.addTarget(self, action: #selector(clearPlan), for: .touchUpInside)
        clear.isHidden = !hasExistingPlan
        let stack = UIStackView(arrangedSubviews: [titleLabel, picker, save, clear])
        stack.axis = .vertical
        stack.spacing = 14
        view.addSubview(stack)
        stack.pin(to: view.safeAreaLayoutGuide, insets: UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
    }

    @objc private func savePlan() {
        dismiss(animated: true) { self.onSave(self.picker.date) }
    }

    @objc private func clearPlan() {
        dismiss(animated: true) { self.onSave(nil) }
    }
}
