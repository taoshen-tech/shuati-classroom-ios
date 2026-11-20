import XCTest
@testable import ShuaTiClassroom

final class StudyModelsTests: XCTestCase {
    func testOnlyNaturalEndMarksChapterDone() {
        var chapter = ChapterState()
        chapter.recordPlayback(position: 100, duration: 100, naturallyFinished: false, at: 1)
        XCTAssertEqual(chapter.status, .watching)
        XCTAssertEqual(chapter.position, 100)

        chapter.recordPlayback(position: 100, duration: 100, naturallyFinished: true, at: 2)
        XCTAssertEqual(chapter.status, .done)
        XCTAssertEqual(chapter.percent, 100)
    }

    func testSavingAfterCompletionDoesNotRevertStatus() {
        var chapter = ChapterState()
        chapter.recordPlayback(position: 80, duration: 80, naturallyFinished: true, at: 1)
        chapter.recordPlayback(position: 12, duration: 80, naturallyFinished: false, at: 2)
        XCTAssertEqual(chapter.status, .done)
        XCTAssertEqual(chapter.position, 12)
    }

    func testManualUnseenResetsPosition() {
        var chapter = ChapterState()
        chapter.recordPlayback(position: 50, duration: 100, naturallyFinished: false, at: 1)
        chapter.toggleDone(at: 2)
        XCTAssertEqual(chapter.status, .done)
        chapter.toggleDone(at: 3)
        XCTAssertEqual(chapter.status, .unseen)
        XCTAssertEqual(chapter.position, 0)
    }

    func testPercentUsesScannedVideoCatalog() {
        var state = CourseState(coursePath: "/course")
        var done = ChapterState()
        done.status = .done
        state.set(done, for: "/course/a.mp4", at: 1)
        XCTAssertNil(state.percent)
        state.updateCatalog(["/course/a.mp4", "/course/b.mp4", "/course/c.mp4"], at: 2)
        XCTAssertEqual(state.total, 3)
        XCTAssertEqual(state.doneCount, 1)
        XCTAssertEqual(state.percent, 33)
    }

    func testMergeUsesNewestChapterAndCatalogIndependently() throws {
        var local = CourseState(coursePath: "/course")
        var localChapter = ChapterState()
        localChapter.position = 20
        localChapter.updatedAt = 10
        local.set(localChapter, for: "/course/a.mp4", at: 10)
        local.updateCatalog(["/course/a.mp4"], at: 10)

        var remote = CourseState(coursePath: "/course")
        var remoteChapter = ChapterState()
        remoteChapter.position = 90
        remoteChapter.updatedAt = 20
        remote.set(remoteChapter, for: "/course/a.mp4", at: 20)
        remote.set(localChapter, for: "/course/b.mp4", at: 10)
        remote.updateCatalog(["/course/a.mp4", "/course/b.mp4"], at: 30)

        let merged = local.merged(with: remote)
        XCTAssertEqual(merged.state(for: "/course/a.mp4").position, 90)
        XCTAssertEqual(merged.state(for: "/course/b.mp4").position, 20)
        XCTAssertEqual(merged.videoPaths.count, 2)
        XCTAssertEqual(merged.catalogUpdatedAt, 30)
    }

    func testFormatPolicyDoesNotPromiseUniversalAVPlayerSupport() {
        XCTAssertTrue(AlistFile(name: "a.MP4", path: "/a.MP4").isDirectlyPlayable)
        XCTAssertTrue(AlistFile(name: "a.m3u8", path: "/a.m3u8").isDirectlyPlayable)
        XCTAssertTrue(AlistFile(name: "a.flv", path: "/a.flv").needsTranscode)
        XCTAssertFalse(AlistFile(name: "a.mkv", path: "/a.mkv").isDirectlyPlayable)
        XCTAssertFalse(AlistFile(name: "notes.pdf", path: "/notes.pdf").isVideo)
    }

    func testClockFormatting() {
        XCTAssertEqual(TimeFormat.clock(65), "01:05")
        XCTAssertEqual(TimeFormat.clock(3661), "01:01:01")
        XCTAssertEqual(TimeFormat.clock(.nan), "00:00")
    }
}
