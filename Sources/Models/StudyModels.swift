import Foundation

struct ServerConfiguration: Codable, Equatable {
    var serverURL = ""
    var courseRoot = ""
    var transcodeURL = ""
    var username = ""

    var isValid: Bool {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return false }
        return !courseRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct Course: Hashable {
    let name: String
    let path: String
    var id: String { path }
}

struct AlistFile: Decodable {
    let name: String
    let path: String
    let isDir: Bool
    let size: Int64
    let modified: String?
    let sign: String?
    let rawURL: String?

    enum CodingKeys: String, CodingKey {
        case name, path, size, modified, sign
        case isDir = "is_dir"
        case rawURL = "raw_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        isDir = try c.decodeIfPresent(Bool.self, forKey: .isDir) ?? false
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        modified = try c.decodeIfPresent(String.self, forKey: .modified)
        sign = try c.decodeIfPresent(String.self, forKey: .sign)
        rawURL = try c.decodeIfPresent(String.self, forKey: .rawURL)
    }

    init(name: String, path: String, isDir: Bool = false, size: Int64 = 0, sign: String? = nil, rawURL: String? = nil) {
        self.name = name
        self.path = path
        self.isDir = isDir
        self.size = size
        self.modified = nil
        self.sign = sign
        self.rawURL = rawURL
    }

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    var isVideo: Bool {
        ["mp4", "mov", "m4v", "m3u8", "flv", "mkv", "avi", "ts", "webm"].contains(fileExtension)
    }

    var isDirectlyPlayable: Bool {
        ["mp4", "mov", "m4v", "m3u8"].contains(fileExtension)
    }

    var needsTranscode: Bool { fileExtension == "flv" }
}

enum StudyStatus: String, Codable {
    case unseen
    case watching
    case done

    var label: String {
        switch self {
        case .unseen: return "未看"
        case .watching: return "在看"
        case .done: return "已看"
        }
    }
}

struct ChapterState: Codable {
    var status: StudyStatus = .unseen
    var position: Double = 0
    var duration: Double = 0
    var planDate: String?
    var updatedAt: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case status, position, duration, planDate, updatedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(StudyStatus.self, forKey: .status) ?? .unseen
        position = max(0, try c.decodeIfPresent(Double.self, forKey: .position) ?? 0)
        duration = max(0, try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0)
        planDate = try c.decodeIfPresent(String.self, forKey: .planDate)
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
    }

    var percent: Int {
        if status == .done { return 100 }
        guard duration > 0 else { return 0 }
        return Int((position / duration * 100).rounded()).clamped(to: 0...99)
    }

    var timeText: String {
        guard duration > 0 else { return "--" }
        return "\(TimeFormat.clock(position)) / \(TimeFormat.clock(duration))"
    }

    /// Only a natural end-of-playback event may set `finished` to true.
    mutating func recordPlayback(position: Double, duration: Double, naturallyFinished: Bool, at timestamp: Int64) {
        if naturallyFinished {
            status = .done
            self.duration = duration > 0 ? duration : self.duration
            self.position = self.duration > 0 ? self.duration : max(position, 0)
        } else {
            self.position = position.isFinite ? max(0, position) : self.position
            self.duration = duration.isFinite && duration > 0 ? duration : self.duration
            if status != .done, self.position > 0 { status = .watching }
        }
        updatedAt = timestamp
    }

    mutating func toggleDone(at timestamp: Int64) {
        status = status == .done ? .unseen : .done
        if status == .unseen { position = 0 }
        updatedAt = timestamp
    }
}

struct CourseState: Codable {
    var version = 2
    var coursePath: String
    var updatedAt: Int64 = 0
    var chapters: [String: ChapterState] = [:]
    var videoPaths: [String] = []
    var catalogUpdatedAt: Int64 = 0

    enum CodingKeys: String, CodingKey {
        case version, coursePath, updatedAt, chapters, videoPaths, catalogUpdatedAt
    }

    init(coursePath: String) { self.coursePath = coursePath }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        coursePath = try c.decodeIfPresent(String.self, forKey: .coursePath) ?? ""
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        chapters = try c.decodeIfPresent([String: ChapterState].self, forKey: .chapters) ?? [:]
        videoPaths = try c.decodeIfPresent([String].self, forKey: .videoPaths) ?? []
        catalogUpdatedAt = try c.decodeIfPresent(Int64.self, forKey: .catalogUpdatedAt) ?? 0
    }

    func state(for path: String) -> ChapterState { chapters[path] ?? ChapterState() }

    mutating func set(_ chapter: ChapterState, for path: String, at timestamp: Int64) {
        chapters[path] = chapter
        updatedAt = timestamp
    }

    mutating func updateCatalog(_ paths: [String], at timestamp: Int64) {
        videoPaths = Array(Set(paths)).sorted()
        catalogUpdatedAt = timestamp
        updatedAt = max(updatedAt, timestamp)
    }

    var hasScannedCatalog: Bool { catalogUpdatedAt > 0 }
    var total: Int { hasScannedCatalog ? videoPaths.count : chapters.count }
    var doneCount: Int {
        let paths = hasScannedCatalog ? videoPaths : Array(chapters.keys)
        return paths.filter { chapters[$0]?.status == .done }.count
    }
    var percent: Int? {
        guard hasScannedCatalog else { return nil }
        guard !videoPaths.isEmpty else { return 100 }
        return Int((Double(doneCount) / Double(videoPaths.count) * 100).rounded())
    }

    var recent: [(path: String, state: ChapterState)] {
        chapters.compactMap { key, value in
            value.status == .watching && value.position > 0 ? (key, value) : nil
        }.sorted { $0.state.updatedAt > $1.state.updatedAt }
    }

    var planned: [(path: String, state: ChapterState)] {
        chapters.compactMap { key, value in
            value.planDate == nil ? nil : (key, value)
        }.sorted {
            if $0.state.planDate == $1.state.planDate { return $0.path < $1.path }
            return ($0.state.planDate ?? "") < ($1.state.planDate ?? "")
        }
    }

    func merged(with other: CourseState) -> CourseState {
        var result = updatedAt >= other.updatedAt ? self : other
        result.coursePath = coursePath.isEmpty ? other.coursePath : coursePath
        for key in Set(chapters.keys).union(other.chapters.keys) {
            switch (chapters[key], other.chapters[key]) {
            case let (a?, b?): result.chapters[key] = a.updatedAt >= b.updatedAt ? a : b
            case let (a?, nil): result.chapters[key] = a
            case let (nil, b?): result.chapters[key] = b
            default: break
            }
        }
        if other.catalogUpdatedAt > catalogUpdatedAt {
            result.videoPaths = other.videoPaths
            result.catalogUpdatedAt = other.catalogUpdatedAt
        }
        result.updatedAt = max(updatedAt, other.updatedAt)
        return result
    }
}

struct PlayItem {
    let course: Course
    let path: String
    let state: ChapterState
    var name: String { (path as NSString).lastPathComponent }
}

enum TimeFormat {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let value = Int(seconds)
        let hours = value / 3600
        let minutes = value % 3600 / 60
        let secs = value % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    static func planDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func planLabel(_ value: String) -> String {
        let today = planDate(Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()).map(planDate)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()).map(planDate)
        if value == today { return "今天 · \(value)" }
        if value == tomorrow { return "明天 · \(value)" }
        if value == yesterday { return "昨天 · \(value)" }
        return value
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

func currentTimestamp() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
