import UIKit

final class HomeViewController: UIViewController {
    private enum Row {
        case course(Course)
        case play(PlayItem)
    }
    private struct Section {
        let title: String
        let rows: [Row]
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var courses: [Course] = []
    private var sections: [Section] = []
    private var observer: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var hasLoaded = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "刷题课堂"
        view.backgroundColor = .systemGroupedBackground
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(openSettings))
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "退出", style: .plain, target: self, action: #selector(confirmLogout))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.delegate = self
        tableView.dataSource = self
        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        tableView.tableHeaderView = makeHeader()
        view.addSubview(tableView)
        tableView.pin(to: view)
        observer = NotificationCenter.default.addObserver(forName: StudyStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildSections()
        }
        refresh()
    }

    deinit {
        loadTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuildSections()
    }

    private func makeHeader() -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 142))
        let card = UIView()
        card.backgroundColor = AppColor.ink
        card.layer.cornerRadius = 22
        container.addSubview(card)
        card.pin(to: container, insets: UIEdgeInsets(top: 4, left: 4, bottom: 16, right: 4))
        let eyebrow = UILabel.make("YOUR STUDY SPACE", size: 11, weight: .bold, color: AppColor.accent)
        let titleLabel = UILabel.make("今天也向前一点", size: 25, weight: .bold, color: .white)
        let note = UILabel.make("记录保存在本机，并按课程同步到你的 NAS。", size: 13, color: UIColor.white.withAlphaComponent(0.68))
        let stack = UIStackView(arrangedSubviews: [eyebrow, titleLabel, note])
        stack.axis = .vertical
        stack.spacing = 8
        card.addSubview(stack)
        stack.pin(to: card, insets: UIEdgeInsets(top: 20, left: 20, bottom: 18, right: 20))
        return container
    }

    @objc private func refresh() {
        guard loadTask == nil else { return }
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.tableView.refreshControl?.endRefreshing()
                self.loadTask = nil
            }
            do {
                self.courses = try await AppEnvironment.shared.api.listCourses()
                // Merge each course independently; one unavailable state file must not block the catalog.
                for course in self.courses {
                    try? await AppEnvironment.shared.studyStore.refreshFromRemote(course: course)
                }
                self.hasLoaded = true
                self.rebuildSections()
            } catch {
                if !Task.isCancelled { self.showError(error, title: "课程加载失败") }
                self.rebuildSections()
            }
        }
    }

    private func rebuildSections() {
        let store = AppEnvironment.shared.studyStore
        let courseNames = Dictionary(uniqueKeysWithValues: courses.map { ($0.path, $0.name) })
        func named(_ item: PlayItem) -> PlayItem {
            PlayItem(course: Course(name: courseNames[item.course.path] ?? item.course.path, path: item.course.path), path: item.path, state: item.state)
        }
        let recent = store.allRecent().map(named).prefix(8)
        let planned = store.allPlanned().map(named).prefix(12)
        var result: [Section] = []
        if !recent.isEmpty { result.append(Section(title: "继续学习", rows: recent.map(Row.play))) }
        if !planned.isEmpty { result.append(Section(title: "学习计划", rows: planned.map(Row.play))) }
        result.append(Section(title: "全部课程 · \(courses.count)", rows: courses.map(Row.course)))
        sections = result
        tableView.reloadData()
        if hasLoaded && courses.isEmpty {
            tableView.backgroundView = emptyLabel("课程根目录里还没有课程\n请检查目录或添加视频文件夹")
        } else {
            tableView.backgroundView = nil
        }
    }

    private func emptyLabel(_ text: String) -> UILabel {
        let label = UILabel.make(text, size: 15, color: .secondaryLabel)
        label.textAlignment = .center
        return label
    }

    @objc private func openSettings() {
        navigationController?.pushViewController(LoginViewController(), animated: true)
    }

    @objc private func confirmLogout() {
        let alert = UIAlertController(title: "退出当前连接？", message: "本机学习记录会保留，服务器地址和凭证将从当前登录状态中移除。", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "退出", style: .destructive) { _ in
            AppEnvironment.shared.logout()
            (UIApplication.shared.delegate as? AppDelegate)?.showLogin()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.leftBarButtonItem
        present(alert, animated: true)
    }

    private func open(course: Course, play path: String? = nil) {
        navigationController?.pushViewController(CourseViewController(course: course, autoplayPath: path), animated: true)
    }
}

extension HomeViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.numberOfLines = 2
        content.secondaryTextProperties.color = .secondaryLabel
        switch sections[indexPath.section].rows[indexPath.row] {
        case .course(let course):
            let state = AppEnvironment.shared.studyStore.state(for: course)
            content.text = course.name
            if let percent = state.percent {
                content.secondaryText = "已看 \(state.doneCount)/\(state.total) · \(percent)%"
            } else {
                content.secondaryText = "打开课程以扫描视频目录"
            }
            content.image = UIImage(systemName: "folder.fill")
            content.imageProperties.tintColor = AppColor.accent
        case .play(let item):
            content.text = item.name
            let plan = item.state.planDate.map { "\(TimeFormat.planLabel($0)) · " } ?? ""
            content.secondaryText = "\(item.course.name) · \(plan)\(item.state.timeText)"
            content.image = UIImage(systemName: "play.circle.fill")
            content.imageProperties.tintColor = AppColor.accent
        }
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .course(let course): open(course: course)
        case .play(let item): open(course: item.course, play: item.path)
        }
    }
}
