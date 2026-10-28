import AppKit
import SwiftUI

/// A native menu preserves the frontmost app's text input context.
struct KeyboardInputMenu: NSViewRepresentable {
    @ObservedObject var keyboard: KeyboardInputStore
    let willOpen: () -> Void
    var dragActions: TrayDragActions? = nil
    var register: (NSView) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(keyboard: keyboard, willOpen: willOpen) }

    func makeNSView(context: Context) -> NSButton {
        let button = DraggableTrayButton(title: "", target: context.coordinator, action: #selector(Coordinator.showMenu(_:)))
        button.bezelStyle = .recessed
        button.showsBorderOnlyWhileMouseInside = true
        button.font = .systemFont(ofSize: 11, weight: .semibold)
        button.setAccessibilityLabel("Keyboard input source")
        button.setAccessibilityHelp("Choose a keyboard language or layout")
        DispatchQueue.main.async { register(button) }
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.willOpen = willOpen
        (button as? DraggableTrayButton)?.dragActions = dragActions
        button.title = keyboard.current?.shortLabel ?? "⌨"
        button.toolTip = keyboard.current.map { "Keyboard input: \($0.name)" } ?? "Keyboard input sources"
        button.setAccessibilityValue(keyboard.current?.name ?? "Unavailable")
    }

    @MainActor
    final class Coordinator: NSObject {
        private let keyboard: KeyboardInputStore
        var willOpen: () -> Void

        init(keyboard: KeyboardInputStore, willOpen: @escaping () -> Void) {
            self.keyboard = keyboard
            self.willOpen = willOpen
        }

        @objc func showMenu(_ sender: NSButton) {
            willOpen()
            keyboard.refresh()
            let menu = NSMenu(title: "Keyboard input sources")
            menu.addItem(withTitle: "Keyboard Input", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
            for source in keyboard.sources {
                let item = menu.addItem(withTitle: source.name, action: #selector(selectSource(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = source.id
                item.state = source.id == keyboard.current?.id ? .on : .off
            }
            if keyboard.sources.isEmpty {
                menu.addItem(withTitle: "No input sources available", action: nil, keyEquivalent: "")
            }
            menu.addItem(.separator())
            let settings = menu.addItem(withTitle: "Keyboard Settings…", action: #selector(openSettings), keyEquivalent: "")
            settings.target = self
            guard let window = sender.window, let screen = window.screen else { return }
            let buttonFrame = window.convertToScreen(sender.convert(sender.bounds, to: nil))
            let size = menu.size
            let margin: CGFloat = 8
            let x = min(max(buttonFrame.midX - size.width / 2, screen.visibleFrame.minX + margin),
                        screen.visibleFrame.maxX - size.width - margin)
            let top = min(window.frame.maxY + margin + size.height, screen.visibleFrame.maxY - margin)
            // NSMenu anchors its TOP edge here. Give it the full height above
            // the bar in screen coordinates, independent of the button's flipped view.
            let location = sender.convert(window.convertPoint(fromScreen: NSPoint(x: x, y: top)), from: nil)
            menu.popUp(positioning: nil, at: location, in: sender)
        }

        @objc private func selectSource(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            keyboard.select(id)
            if let error = keyboard.error {
                let alert = NSAlert()
                alert.messageText = "Couldn’t switch keyboard input"
                alert.informativeText = error
                alert.alertStyle = .warning
                alert.runModal()
            }
        }

        @objc private func openSettings() {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
