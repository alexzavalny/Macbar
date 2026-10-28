import AppKit
import ApplicationServices
import Combine
import ScreenCaptureKit

struct WindowPreview: Identifiable {
    let id: CGWindowID
    let processID: pid_t
    let title: String
    let frame: CGRect
    var image: NSImage?
}

@MainActor
protocol WindowPreviewProviding {
    func windows(for bundleID: String) async throws -> [WindowPreview]
    func image(for window: WindowPreview) async throws -> NSImage?
}

@MainActor
final class WindowPreviewStore: ObservableObject {
    enum State: Equatable { case idle, permissionRequired, loading, ready, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var windows: [WindowPreview] = []
    private let provider: WindowPreviewProviding
    private let hasAccess: () -> Bool
    private var task: Task<Void, Never>?
    private var requestID = UUID()

    init(provider: WindowPreviewProviding? = nil,
         hasAccess: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.provider = provider ?? ScreenCapturePreviewProvider()
        self.hasAccess = hasAccess
    }

    func show(_ item: ApplicationItem) {
        cancel()
        guard hasAccess() else { state = .permissionRequired; return }
        state = .loading
        let request = requestID
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await provider.windows(for: item.id)
                guard !Task.isCancelled, requestID == request else { return }
                windows = result
                state = .ready
                for window in result {
                    guard !Task.isCancelled, requestID == request else { return }
                    let image = try? await provider.image(for: window)
                    guard !Task.isCancelled, requestID == request else { return }
                    if let index = windows.firstIndex(where: { $0.id == window.id }) {
                        windows[index].image = image
                    }
                }
            } catch {
                guard !Task.isCancelled, requestID == request else { return }
                state = hasAccess() ? .failed : .permissionRequired
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        requestID = UUID()
        windows = []
        state = .idle
    }

    func requestAccess() {
        // Hovering never opens a system permission prompt. Only this button does.
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

@MainActor
final class ScreenCapturePreviewProvider: WindowPreviewProviding {
    private var sources: [CGWindowID: SCWindow] = [:]

    func windows(for bundleID: String) async throws -> [WindowPreview] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let windows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 &&
            $0.frame.width > 1 && $0.frame.height > 1
        }.sorted { $0.windowID < $1.windowID }
        sources = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        return windows.map {
            WindowPreview(id: $0.windowID, processID: $0.owningApplication!.processID,
                          title: $0.title?.isEmpty == false ? $0.title! : "Untitled window", frame: $0.frame)
        }
    }

    func image(for window: WindowPreview) async throws -> NSImage? {
        guard let source = sources[window.id] else { return nil }
        let configuration = SCStreamConfiguration()
        let scale = min(560 / window.frame.width, 360 / window.frame.height, 2)
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: source), configuration: configuration)
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

enum WindowPreviewGeometry {
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 8
    static let thumbnailSize = CGSize(width: 212, height: 140)
    static let cardPadding: CGFloat = 4
    static let titleSpacing: CGFloat = 6
    static let titleHeight: CGFloat = 14
    static let headerHeight: CGFloat = 20
    static var cardWidth: CGFloat { thumbnailSize.width + cardPadding * 2 }
    static var cardHeight: CGFloat { thumbnailSize.height + titleSpacing + titleHeight + cardPadding * 2 }

    static func panelFrame(anchor: CGRect, screen: CGRect, barTop: CGFloat, windowCount: Int) -> CGRect {
        let contentWidth = CGFloat(windowCount) * cardWidth + CGFloat(max(0, windowCount - 1)) * spacing + padding * 2
        let width = min(windowCount == 0 ? 300 : contentWidth, min(920, screen.width - 24))
        let contentHeight = windowCount == 0 ? 180 : padding * 2 + headerHeight + spacing + cardHeight + (contentWidth > width ? 16 : 0)
        let height = min(contentHeight, max(0, screen.maxY - barTop - 24))
        let x = min(max(anchor.midX - width / 2, screen.minX + 12), screen.maxX - width - 12)
        return CGRect(x: x, y: barTop + 10, width: width, height: height)
    }
}

/// Public Accessibility APIs identify the selected window by its bounds/title.
/// An app without Accessibility access still opens normally when a preview is clicked.
enum PreviewWindowActivation {
    static func activate(_ window: WindowPreview) {
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let application = AXUIElementCreateApplication(window.processID)
            AXUIElementSetMessagingTimeout(application, 0.2)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return }
            let target = windows.first { element in
                var positionValue: CFTypeRef?
                var sizeValue: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
                AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
                guard let positionValue, let sizeValue,
                      CFGetTypeID(positionValue) == AXValueGetTypeID(),
                      CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return false }
                var position = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                let frame = CGRect(origin: position, size: size)
                return abs(frame.minX - window.frame.minX) < 3 && abs(frame.minY - window.frame.minY) < 3 &&
                    abs(frame.width - window.frame.width) < 3 && abs(frame.height - window.frame.height) < 3 &&
                    (windows.count == 1 || title(of: element) == window.title)
            } ?? windows.first { title(of: $0) == window.title }
            guard let target else { return }
            AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, target)
        }
    }

    private static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        return value as? String
    }
}
