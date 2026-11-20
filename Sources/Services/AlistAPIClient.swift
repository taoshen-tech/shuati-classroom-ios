import Foundation

struct AlistAPIClient {
    let configuration: ServerConfiguration
    let token: String
    var session: URLSession = .shared

    private var baseURL: URL {
        URL(string: configuration.serverURL.trimmingCharacters(in: .whitespacesAndNewlines))!
    }

    static func login(configuration: ServerConfiguration, password: String, session: URLSession = .shared) async throws -> String {
        let client = AlistAPIClient(configuration: configuration, token: "", session: session)
        let payload: LoginPayload = try await client.request(
            "/api/auth/login",
            method: "POST",
            body: ["username": configuration.username, "password": password, "otp_code": ""],
            authorized: false
        )
        guard !payload.token.isEmpty else { throw AlistError.invalidResponse }
        return payload.token
    }

    func listCourses() async throws -> [Course] {
        let root = normalized(configuration.courseRoot)
        let entries = try await list(path: root, refresh: false)
        var courses = entries.filter { $0.isDir && $0.name != ".shuati-classroom" }.map {
            Course(name: $0.name, path: resolvedPath(for: $0, parent: root))
        }
        if entries.contains(where: { !$0.isDir && $0.isVideo }) {
            let name = URL(fileURLWithPath: root).lastPathComponent
            courses.insert(Course(name: name.isEmpty ? "课程" : name, path: root), at: 0)
        }
        return courses.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func scanVideos(course: Course, refresh: Bool = false) async throws -> [AlistFile] {
        var visited = Set<String>()
        return try await scan(directory: normalized(course.path), refresh: refresh, visited: &visited)
            .sorted { $0.resolvedPath.localizedStandardCompare($1.resolvedPath) == .orderedAscending }
    }

    private func scan(directory: String, refresh: Bool, visited: inout Set<String>) async throws -> [AlistFile] {
        guard !visited.contains(directory) else { return [] }
        visited.insert(directory)
        var result: [AlistFile] = []
        for entry in try await list(path: directory, refresh: refresh) {
            let path = resolvedPath(for: entry, parent: directory)
            if entry.isDir {
                guard entry.name != ".shuati-classroom" else { continue }
                result.append(contentsOf: try await scan(directory: path, refresh: refresh, visited: &visited))
            } else if entry.isVideo {
                result.append(entry.withPath(path))
            }
        }
        return result
    }

    func playbackURL(for file: AlistFile) async throws -> URL {
        let info = try await get(path: file.resolvedPath)
        let source = info.rawURL?.isEmpty == false ? info.rawURL! : file.rawURL
        guard let source, let url = absoluteURL(source) else { throw AlistError.missingPlaybackURL }
        if file.isDirectlyPlayable { return url }
        guard file.needsTranscode else { throw AlistError.unsupportedFormat(file.fileExtension) }
        return try transcodeURL(source: url)
    }

    func readCourseState(coursePath: String) async throws -> CourseState? {
        do {
            let info = try await get(path: statePath(for: coursePath))
            guard let raw = info.rawURL, let url = absoluteURL(raw) else { return nil }
            var request = URLRequest(url: url)
            if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "Authorization") }
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
            return try JSONDecoder().decode(CourseState.self, from: data)
        } catch let error as AlistError where error.isMissingObject {
            return nil
        }
    }

    func writeCourseState(_ state: CourseState) async throws {
        let data = try JSONEncoder.pretty.encode(state)
        var request = URLRequest(url: endpoint("/api/fs/put"))
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue(statePath(for: state.coursePath).addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "/._-"))), forHTTPHeaderField: "File-Path")
        request.setValue("false", forHTTPHeaderField: "As-Dir")
        request.setValue("true", forHTTPHeaderField: "Overwrite")
        let (responseData, response) = try await session.data(for: request)
        try validate(response: response, data: responseData)
        if !responseData.isEmpty {
            let envelope = try JSONDecoder().decode(EmptyEnvelope.self, from: responseData)
            guard envelope.code == 200 else { throw AlistError.api(code: envelope.code, message: envelope.message) }
        }
    }

    private func list(path: String, refresh: Bool) async throws -> [AlistFile] {
        let payload: ListPayload = try await request("/api/fs/list", method: "POST", body: [
            "path": path,
            "password": "",
            "page": 1,
            "per_page": 0,
            "refresh": refresh
        ])
        return payload.content ?? []
    }

    private func get(path: String) async throws -> AlistFile {
        try await request("/api/fs/get", method: "POST", body: ["path": path, "password": ""])
    }

    private func request<T: Decodable>(_ path: String, method: String, body: [String: Any], authorized: Bool = true) async throws -> T {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized { request.setValue(token, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let envelope: Envelope<T>
        do { envelope = try JSONDecoder().decode(Envelope<T>.self, from: data) }
        catch { throw AlistError.invalidResponse }
        guard envelope.code == 200 else { throw AlistError.api(code: envelope.code, message: envelope.message) }
        guard let payload = envelope.data else { throw AlistError.invalidResponse }
        return payload
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AlistError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw AlistError.http(status: http.statusCode, message: message)
        }
    }

    private func endpoint(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private func absoluteURL(_ value: String) -> URL? {
        if let url = URL(string: value), url.scheme != nil { return url }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    private func transcodeURL(source: URL) throws -> URL {
        let template = configuration.transcodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { throw AlistError.transcodeNotConfigured }
        let sourceString = source.absoluteString
        if template.contains("{url}") {
            let escaped = sourceString.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? sourceString
            guard let url = URL(string: template.replacingOccurrences(of: "{url}", with: escaped)) else {
                throw AlistError.invalidTranscodeURL
            }
            return url
        }
        guard var components = URLComponents(string: template) else { throw AlistError.invalidTranscodeURL }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "url" }
        items.append(URLQueryItem(name: "url", value: sourceString))
        components.queryItems = items
        guard let url = components.url else { throw AlistError.invalidTranscodeURL }
        return url
    }

    private func statePath(for coursePath: String) -> String {
        let id = Data(coursePath.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return normalized(configuration.courseRoot) + "/.shuati-classroom/" + id + ".json"
    }

    private func resolvedPath(for file: AlistFile, parent: String) -> String {
        file.path.isEmpty ? normalized(parent) + "/" + file.name : normalized(file.path)
    }

    private func normalized(_ path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.hasPrefix("/") { value = "/" + value }
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

private extension AlistFile {
    var resolvedPath: String { path }
    func withPath(_ value: String) -> AlistFile {
        AlistFile(name: name, path: value, isDir: isDir, size: size, sign: sign, rawURL: rawURL)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

enum AlistError: LocalizedError {
    case invalidResponse
    case missingPlaybackURL
    case unsupportedFormat(String)
    case transcodeNotConfigured
    case invalidTranscodeURL
    case api(code: Int, message: String)
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无法识别的数据"
        case .missingPlaybackURL: return "未获取到视频播放地址"
        case .unsupportedFormat(let value): return "暂不支持直接播放 .\(value) 文件，请转换为 MP4"
        case .transcodeNotConfigured: return "FLV 视频需要先在设置中填写 NAS 转封装地址"
        case .invalidTranscodeURL: return "转封装地址无效"
        case .api(_, let message): return message.isEmpty ? "Alist 请求失败" : message
        case .http(let status, _): return "网络请求失败（HTTP \(status)）"
        }
    }

    var isMissingObject: Bool {
        switch self {
        case .http(let status, _): return status == 404
        case .api(_, let message):
            let value = message.lowercased()
            return value.contains("object not found") || value.contains("file not found") || message.contains("文件不存在")
        default: return false
        }
    }
}

private struct Envelope<T: Decodable>: Decodable {
    let code: Int
    let message: String
    let data: T?
}

private struct EmptyEnvelope: Decodable {
    let code: Int
    let message: String
}

private struct LoginPayload: Decodable { let token: String }
private struct ListPayload: Decodable { let content: [AlistFile]? }
