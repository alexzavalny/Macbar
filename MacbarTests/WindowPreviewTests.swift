import XCTest
import Combine
@testable import Macbar

@MainActor
private final class PreviewProviderStub: WindowPreviewProviding {
    var requests: [String] = []
    var continuations: [String: CheckedContinuation<[WindowPreview], Error>] = [:]
    var captures: [CGWindowID] = []
    var failImages = false
    var suspendImages = false
    var imageContinuation: CheckedContinuation<NSImage?, Error>?

    func windows(for bundleID: String) async throws -> [WindowPreview] {
        requests.append(bundleID)
        return try await withCheckedThrowingContinuation { continuations[bundleID] = $0 }
    }
    func image(for window: WindowPreview) async throws -> NSImage? {
        captures.append(window.id)
        if suspendImages {
            return try await withCheckedThrowingContinuation { imageContinuation = $0 }
        }
        if failImages { throw NSError(domain: "Capture", code: 1) }
        return NSImage(size: NSSize(width: 120, height: 80))
    }
    func finish(_ bundleID: String, windows: [WindowPreview]) {
        continuations.removeValue(forKey: bundleID)?.resume(returning: windows)
    }
}

final class WindowPreviewTests: XCTestCase {
    @MainActor
    private func app(_ id: String) -> ApplicationItem {
        ApplicationItem(id: id, name: id, url: URL(fileURLWithPath: "/Applications/\(id).app"), icon: NSImage())
    }
    private func window(_ id: CGWindowID) -> WindowPreview {
        WindowPreview(id: id, processID: 123, title: "Window \(id)", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    @MainActor
    func testHoverWithoutPermissionDoesNotEnumerateOrCapture() async {
        let provider = PreviewProviderStub()
        let store = WindowPreviewStore(provider: provider, hasAccess: { false })
        store.show(app("A"))
        await Task.yield()
        XCTAssertEqual(store.state, .permissionRequired)
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertTrue(provider.captures.isEmpty)
    }

    @MainActor
    func testSwitchingAppsDiscardsLateResults() async throws {
        let provider = PreviewProviderStub()
        let store = WindowPreviewStore(provider: provider, hasAccess: { true })
        store.show(app("A"))
        while provider.continuations["A"] == nil { await Task.yield() }
        store.show(app("B"))
        while provider.continuations["B"] == nil { await Task.yield() }
        provider.finish("A", windows: [window(1)])
        provider.finish("B", windows: [window(2), window(3)])
        for _ in 0..<100 where provider.captures.count < 2 { await Task.yield() }
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.windows.map(\.id), [2, 3])
        XCTAssertEqual(provider.captures, [2, 3])
        XCTAssertTrue(store.windows.allSatisfy { $0.image != nil })
    }

    @MainActor
    func testDismissalDiscardsInFlightEnumeration() async {
        let provider = PreviewProviderStub()
        let store = WindowPreviewStore(provider: provider, hasAccess: { true })
        store.show(app("A"))
        while provider.continuations["A"] == nil { await Task.yield() }
        store.cancel()
        provider.finish("A", windows: [window(1)])
        await Task.yield()
        XCTAssertEqual(store.state, .idle)
        XCTAssertTrue(store.windows.isEmpty)
        XCTAssertTrue(provider.captures.isEmpty)
    }

    @MainActor
    func testDismissalDiscardsInFlightThumbnail() async {
        let provider = PreviewProviderStub()
        provider.suspendImages = true
        let store = WindowPreviewStore(provider: provider, hasAccess: { true })
        store.show(app("A"))
        while provider.continuations["A"] == nil { await Task.yield() }
        provider.finish("A", windows: [window(1), window(2)])
        while provider.imageContinuation == nil { await Task.yield() }
        store.cancel()
        provider.imageContinuation?.resume(returning: NSImage())
        await Task.yield()
        XCTAssertEqual(store.state, .idle)
        XCTAssertTrue(store.windows.isEmpty)
        XCTAssertEqual(provider.captures, [1])
    }

    @MainActor
    func testEnumerationFailureShowsRetryState() async {
        let provider = PreviewProviderStub()
        let store = WindowPreviewStore(provider: provider, hasAccess: { true })
        store.show(app("A"))
        while provider.continuations["A"] == nil { await Task.yield() }
        provider.continuations.removeValue(forKey: "A")?.resume(throwing: NSError(domain: "Capture", code: 1))
        for _ in 0..<100 where store.state == .loading { await Task.yield() }
        XCTAssertEqual(store.state, .failed)
        XCTAssertTrue(store.windows.isEmpty)
    }

    @MainActor
    func testIndividualCaptureFailureKeepsOtherWindows() async {
        let provider = PreviewProviderStub()
        provider.failImages = true
        let store = WindowPreviewStore(provider: provider, hasAccess: { true })
        store.show(app("A"))
        while provider.continuations["A"] == nil { await Task.yield() }
        provider.finish("A", windows: [window(1), window(2)])
        for _ in 0..<100 where provider.captures.count < 2 { await Task.yield() }
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.windows.map(\.id), [1, 2])
        XCTAssertEqual(provider.captures, [1, 2])
    }

    @MainActor
    func testNoWindowsIsReadyAndDoesNotCapture() async {
        let provider = PreviewProviderStub()
        let store = WindowPreviewStore(provider: provider, hasAccess: { true })
        store.show(app("A"))
        while provider.continuations["A"] == nil { await Task.yield() }
        provider.finish("A", windows: [])
        for _ in 0..<100 where store.state == .loading { await Task.yield() }
        XCTAssertEqual(store.state, .ready)
        XCTAssertTrue(store.windows.isEmpty)
        XCTAssertTrue(provider.captures.isEmpty)
    }

    func testPreviewIsClampedToDisplayEdgesAndCenteredOnIcon() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1050)
        for x in [screen.minX, screen.midX, screen.maxX] {
            let anchor = CGRect(x: x - 22, y: -200, width: 44, height: 54)
            let frame = WindowPreviewGeometry.panelFrame(anchor: anchor, screen: screen, barTop: -146, windowCount: 12)
            XCTAssertTrue(screen.contains(frame))
            XCTAssertEqual(frame.minY, -136)
            if x == screen.midX { XCTAssertEqual(frame.midX, anchor.midX) }
        }
    }

    func testPreviewFitsSmallDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 320, height: 280)
        let frame = WindowPreviewGeometry.panelFrame(anchor: CGRect(x: 0, y: 0, width: 44, height: 54),
                                                    screen: screen, barTop: 54, windowCount: 20)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.width, 296)
    }
}
