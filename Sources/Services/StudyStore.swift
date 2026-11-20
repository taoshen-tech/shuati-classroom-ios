import Foundation

@MainActor
final class StudyStore {
    static let didChangeNotification = Notification.Name("StudyStore.didChange")
    nonisolated static let coursePathUserInfoKey = "coursePath"

    private unowned let environment: AppEnvironment
    private var states: [String: CourseState] = [:]
    private var revisions: [String: Int] = [:]
    private var syncTasks: [String: Task<Void, Never>] = [:]
    private var syncing = Set<String>()
    private(set) var syncErrors: [String: String] = [:]
    private(set) var lastSyncDates: [String: Date] = [:]

    private let fileManager = FileManager.default
    private lazy var cacheDirectory: URL = {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("CourseStates", isDirectory: true)
    }()

    init(environment: AppEnvironment) {
        self.environment = environment
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func state(for course: Course) -> CourseState {
        if let value = states[course.path] { return value }
        let value = loadLocal(coursePath: course.path) ?? CourseState(coursePath: course.path)
        states[course.path] = value
        return value
    }

    func cachedCourses() -> [Course] {
        states.values.map { Course(name: URL(fileURLWithPath: $0.coursePath).lastPathComponent, path: $0.coursePath) }
    }

    func allRecent() -> [PlayItem] {
        states.values.flatMap { state in
            state.recent.map { PlayItem(course: Course(name: "", path: state.coursePath), path: $0.path, state: $0.state) }
        }.sorted { $0.state.updatedAt > $1.state.updatedAt }
    }

    func allPlanned() -> [PlayItem] {
        states.values.flatMap { state in
            state.planned.map { PlayItem(course: Course(name: "", path: state.coursePath), path: $0.path, state: $0.state) }
        }.sorted {
            if $0.state.planDate == $1.state.planDate { return $0.state.updatedAt > $1.state.updatedAt }
            return ($0.state.planDate ?? "") < ($1.state.planDate ?? "")
        }
    }

    func recordPlayback(course: Course, path: String, position: Double, duration: Double, naturallyFinished: Bool) {
        mutate(course: course, path: path) { chapter in
            chapter.recordPlayback(position: position, duration: duration, naturallyFinished: naturallyFinished, at: currentTimestamp())
        }
    }

    func toggleDone(course: Course, path: String) {
        mutate(course: course, path: path) { $0.toggleDone(at: currentTimestamp()) }
    }

    func setPlanDate(_ date: Date?, course: Course, path: String) {
        mutate(course: course, path: path) { chapter in
            chapter.planDate = date.map(TimeFormat.planDate)
            chapter.updatedAt = currentTimestamp()
        }
    }

    func updateCatalog(course: Course, paths: [String]) {
        var value = state(for: course)
        value.updateCatalog(paths, at: currentTimestamp())
        states[course.path] = value
        bumpRevision(course.path)
        saveLocal(value)
        notify(course.path)
        scheduleUpload(course.path, delay: 1.5)
    }

    func refreshFromRemote(course: Course) async throws {
        _ = state(for: course)
        guard let remote = try await environment.api.readCourseState(coursePath: course.path) else { return }
        let merged = state(for: course).merged(with: remote)
        states[course.path] = merged
        saveLocal(merged)
        notify(course.path)
    }

    func flush(course: Course) async throws {
        while syncing.contains(course.path) {
            try await Task.sleep(nanoseconds: 100_000_000)
            try Task.checkCancellation()
        }
        syncTasks[course.path]?.cancel()
        syncTasks[course.path] = nil
        try await performSync(course.path)
    }

    func flushAll() async {
        for path in Array(states.keys) {
            try? await flush(course: Course(name: "", path: path))
        }
    }

    private func mutate(course: Course, path: String, change: (inout ChapterState) -> Void) {
        var value = state(for: course)
        var chapter = value.state(for: path)
        change(&chapter)
        value.set(chapter, for: path, at: currentTimestamp())
        states[course.path] = value
        bumpRevision(course.path)
        saveLocal(value)
        notify(course.path)
        scheduleUpload(course.path, delay: 1.2)
    }

    private func scheduleUpload(_ coursePath: String, delay: Double) {
        guard !syncing.contains(coursePath) else { return }
        syncTasks[coursePath]?.cancel()
        syncTasks[coursePath] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            try? await self?.performSync(coursePath)
        }
    }

    private func performSync(_ coursePath: String) async throws {
        guard !syncing.contains(coursePath) else { return }
        syncing.insert(coursePath)
        defer {
            syncing.remove(coursePath)
            syncTasks[coursePath] = nil
        }
        do {
            // A mutation made during a network request is merged and sent in the next loop.
            // Different courses never share a task or overwrite one another.
            while !Task.isCancelled {
                let snapshot = state(for: Course(name: "", path: coursePath))
                let revision = revisions[coursePath] ?? 0
                let remote = try await environment.api.readCourseState(coursePath: coursePath)
                let merged = remote.map { snapshot.merged(with: $0) } ?? snapshot
                try await environment.api.writeCourseState(merged)
                let current = state(for: Course(name: "", path: coursePath))
                states[coursePath] = current.merged(with: merged)
                saveLocal(states[coursePath]!)
                syncErrors[coursePath] = nil
                lastSyncDates[coursePath] = Date()
                notify(coursePath)
                if revisions[coursePath] == revision { break }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        } catch {
            guard !Task.isCancelled else { return }
            syncErrors[coursePath] = error.localizedDescription
            notify(coursePath)
            throw error
        }
    }

    private func bumpRevision(_ coursePath: String) {
        revisions[coursePath] = (revisions[coursePath] ?? 0) + 1
    }

    private func notify(_ coursePath: String) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.coursePathUserInfoKey: coursePath]
        )
    }

    private func localURL(coursePath: String) -> URL {
        let id = Data(coursePath.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return cacheDirectory.appendingPathComponent(id + ".json")
    }

    private func loadLocal(coursePath: String) -> CourseState? {
        guard let data = try? Data(contentsOf: localURL(coursePath: coursePath)) else { return nil }
        return try? JSONDecoder().decode(CourseState.self, from: data)
    }

    private func saveLocal(_ state: CourseState) {
        guard let data = try? JSONEncoder.pretty.encode(state) else { return }
        try? data.write(to: localURL(coursePath: state.coursePath), options: .atomic)
    }
}
