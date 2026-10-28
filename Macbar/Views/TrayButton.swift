import AppKit
import SwiftUI

struct TrayDragActions {
    var changed: (CGPoint, CGSize, CGRect) -> Void
    var ended: (CGPoint) -> Void
}

/// Track the mouse before invoking the click action, including for native input menus.
final class DraggableTrayButton: NSButton {
    var dragActions: TrayDragActions?
    var appearanceChanged: (() -> Void)?
    private(set) var hovered = false
    private(set) var pressed = false
    private var hoverTracking: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; appearanceChanged?() }
    override func mouseExited(with event: NSEvent) { hovered = false; appearanceChanged?() }

    override func mouseDown(with event: NSEvent) {
        guard let window, let dragActions else { super.mouseDown(with: event); return }
        let start = window.convertPoint(toScreen: event.locationInWindow)
        let originalFrame = window.convertToScreen(convert(bounds, to: nil))
        var dragging = false
        pressed = true
        appearanceChanged?()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                                           until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let point = window.convertPoint(toScreen: next.locationInWindow)
            if next.type == .keyDown {
                if next.keyCode == 53 {
                    if dragging { dragActions.ended(CGPoint(x: -CGFloat.greatestFiniteMagnitude, y: 0)) }
                    break
                }
                continue
            }
            if next.type == .leftMouseUp {
                pressed = false
                appearanceChanged?()
                if dragging { dragActions.ended(point) }
                else if originalFrame.contains(point) { performClick(nil) }
                break
            }
            let translation = CGSize(width: point.x - start.x, height: start.y - point.y)
            if dragging || hypot(translation.width, translation.height) >= 5 {
                dragging = true
                pressed = false
                appearanceChanged?()
                dragActions.changed(point, translation, originalFrame)
            }
        }
        pressed = false
        appearanceChanged?()
    }
}

struct TrayButton<Label: View>: NSViewRepresentable {
    var selected: Bool
    let accessibilityLabel: String
    var accessibilityValue: String = ""
    let help: String
    let dragActions: TrayDragActions
    let register: (NSView) -> Void
    let action: () -> Void
    @ViewBuilder var label: Label

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> DraggableTrayButton {
        let button = DraggableTrayButton(title: "", target: context.coordinator, action: #selector(Coordinator.clicked))
        button.isBordered = false
        let host = NSHostingView(rootView: surface(hovered: false, pressed: false))
        host.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor), host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor), host.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        context.coordinator.host = host
        DispatchQueue.main.async { register(button) }
        return button
    }

    func updateNSView(_ button: DraggableTrayButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(accessibilityValue)
        button.toolTip = help
        button.dragActions = dragActions
        let host = context.coordinator.host
        button.appearanceChanged = { [weak button, weak host] in
            guard let button else { return }
            host?.rootView = surface(hovered: button.hovered, pressed: button.pressed)
        }
        host?.rootView = surface(hovered: button.hovered, pressed: button.pressed)
    }

    private func surface(hovered: Bool, pressed: Bool) -> TrayButtonSurface<Label> {
        TrayButtonSurface(label: label, selected: selected, hovered: hovered, pressed: pressed)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        var host: NSHostingView<TrayButtonSurface<Label>>?
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked() { action() }
    }
}

struct TrayButtonSurface<Label: View>: View {
    let label: Label
    let selected: Bool
    let hovered: Bool
    let pressed: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        label.accessibilityHidden(true).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(pressed ? (colorScheme == .dark ? 0.06 : 0.30) : (hovered || selected) ? (colorScheme == .dark ? 0.13 : 0.58) : 0))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(hovered || selected ? 0.20 : 0)) }
            }
    }
}
