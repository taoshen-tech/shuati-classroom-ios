import XCTest
@testable import ShuaTiClassroom

final class AlistAPIClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testRecursiveScanAndExplicitListPaging() async throws {
        URLProtocolStub.handler = { request in
            let body = request.bodyJSON
            XCTAssertEqual(body["page"] as? Int, 1)
            XCTAssertEqual(body["per_page"] as? Int, 0)
            let path = body["path"] as? String
            let files: [[String: Any]]
            switch path {
            case "/root":
                files = [["name": "01.mp4", "is_dir": false], ["name": "章节", "is_dir": true]]
            case "/root/章节":
                files = [["name": "02.mp4", "is_dir": false], ["name": "说明.txt", "is_dir": false]]
            default:
                files = []
            }
            return Self.jsonResponse(["code": 200, "message": "success", "data": ["content": files]])
        }
        let client = makeClient()
        let files = try await client.scanVideos(course: Course(name: "课程", path: "/root"))
        XCTAssertEqual(files.map(\.path), ["/root/01.mp4", "/root/章节/02.mp4"])
    }

    func testDirectPlaybackUsesRawURL() async throws {
        URLProtocolStub.handler = { _ in
            Self.jsonResponse(["code": 200, "message": "success", "data": [
                "name": "01.mp4", "path": "/root/01.mp4", "is_dir": false,
                "raw_url": "https://media.example.com/01.mp4"
            ]])
        }
        let url = try await makeClient().playbackURL(for: AlistFile(name: "01.mp4", path: "/root/01.mp4"))
        XCTAssertEqual(url.absoluteString, "https://media.example.com/01.mp4")
    }

    func testMissingRemoteStateIsNotAnError() async throws {
        URLProtocolStub.handler = { _ in
            Self.jsonResponse(["code": 500, "message": "object not found"])
        }
        let state = try await makeClient().readCourseState(coursePath: "/root")
        XCTAssertNil(state)
    }

    private func makeClient() -> AlistAPIClient {
        let configuration = ServerConfiguration(serverURL: "https://alist.example.com", courseRoot: "/root", transcodeURL: "", username: "test")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [URLProtocolStub.self]
        return AlistAPIClient(configuration: configuration, token: "token", session: URLSession(configuration: sessionConfiguration))
    }

    private static func jsonResponse(_ object: [String: Any]) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: URL(string: "https://alist.example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, try! JSONSerialization.data(withJSONObject: object))
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    var bodyJSON: [String: Any] {
        if let httpBody {
            return (try? JSONSerialization.jsonObject(with: httpBody)) as? [String: Any] ?? [:]
        }
        guard let httpBodyStream else { return [:] }
        httpBodyStream.open()
        defer { httpBodyStream.close() }
        let data = NSMutableData()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while httpBodyStream.hasBytesAvailable {
            let count = httpBodyStream.read(buffer, maxLength: 4096)
            guard count > 0 else { break }
            data.append(buffer, length: count)
        }
        return (try? JSONSerialization.jsonObject(with: data as Data)) as? [String: Any] ?? [:]
    }
}
