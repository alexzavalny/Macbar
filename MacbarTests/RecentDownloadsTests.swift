import XCTest
@testable import Macbar

final class RecentDownloadsTests: XCTestCase {
    func testScanIncludesOnlyCompletedVisibleFilesAtTheFolderRoot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Report.pdf", "Photo.png", ".hidden", "Video.crdownload", "Archive.part", "Browser.download", "Cache.tmp"] {
            try Data("fixture".utf8).write(to: directory.appendingPathComponent(name))
        }
        let nested = directory.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("Nested.txt"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("Alias.pdf"),
            withDestinationURL: directory.appendingPathComponent("Report.pdf"))

        let files = try RecentDownload.scan(directory: directory, limit: 20)
        XCTAssertEqual(Set(files.map { $0.url.lastPathComponent }), ["Report.pdf", "Photo.png"])
        XCTAssertTrue(files.allSatisfy { $0.byteCount == 7 })
    }

    func testRecentOrderUsesNewestDatesWithStableTiesAndLimits() {
        let old = file("Old.pdf", date: 1)
        let first = file("A.pdf", date: 3)
        let second = file("B.pdf", date: 3)
        let middle = file("Middle.pdf", date: 2)
        XCTAssertEqual(RecentDownload.newest([old, second, middle, first], limit: 3), [first, second, middle])
        XCTAssertTrue(RecentDownload.newest([old], limit: 0).isEmpty)
        XCTAssertTrue(RecentDownload.newest([old], limit: -1).isEmpty)
    }

    func testDownloadedFileWithOldModificationDateStillCountsAsRecent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Imported.pdf")
        let before = Date().addingTimeInterval(-5)
        try Data("fixture".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)
        let recent = try XCTUnwrap(RecentDownload.scan(directory: directory).first)
        XCTAssertGreaterThan(recent.date, before)
    }

    @MainActor
    func testStoreShowsEmptyFolderAndReportsUnavailableFolder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentDownloadsStore(directory: directory)
        await store.refresh()
        XCTAssertFalse(store.isLoading)
        XCTAssertTrue(store.files.isEmpty)
        XCTAssertNil(store.error)
        try FileManager.default.removeItem(at: directory)
        await store.refresh()
        XCTAssertFalse(store.isLoading)
        XCTAssertTrue(store.files.isEmpty)
        XCTAssertNotNil(store.error)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecentDownloadsTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func file(_ name: String, date: TimeInterval) -> RecentDownload {
        RecentDownload(url: URL(fileURLWithPath: "/Downloads/\(name)"), name: name,
            date: Date(timeIntervalSince1970: date), byteCount: 100)
    }
}
