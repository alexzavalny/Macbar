import SwiftUI

struct TaskbarTrayView: View {
    @ObservedObject var controller: TaskbarController
    @ObservedObject var preferences: Preferences
    @ObservedObject var audio: AudioStore
    @ObservedObject var battery: BatteryStore
    @ObservedObject var wifi: WiFiStore
    @ObservedObject var keyboard: KeyboardInputStore
    @ObservedObject var aiLimits: AILimitsStore
    @State private var draggedItem: TrayItem?
    @State private var pendingOrder: [TrayItem]?
    @State private var buttons: [TrayItem: NSView] = [:]

    private var visibleItems: [TrayItem] {
        (pendingOrder ?? preferences.trayOrder).filter {
            ($0.control.map(preferences.shows) ?? true) && ($0 != .battery || battery.state != nil)
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(visibleItems) { item in
                Group {
                    if item == .inputLanguage {
                        KeyboardInputMenu(keyboard: keyboard, willOpen: { controller.dismissPopup() },
                                          dragActions: dragActions(for: item), register: { buttons[item] = $0 })
                    } else {
                        TrayButton(selected: controller.popup == popup(for: item),
                                   accessibilityLabel: title(for: item),
                                   accessibilityValue: item == .battery ? battery.state?.summary ?? "" : "",
                                   help: help(for: item), dragActions: dragActions(for: item),
                                   register: { buttons[item] = $0 }, action: { controller.toggle(popup(for: item)) }) {
                            label(for: item)
                        }
                    }
                }
                .frame(width: width(for: item), height: 44)
                .opacity(draggedItem == item ? 0 : 1)
            }
        }
        .onDisappear { cancelDrag() }
    }

    private func dragActions(for item: TrayItem) -> TrayDragActions {
        TrayDragActions(changed: { point, translation, frame in
            if draggedItem == nil {
                controller.dismissPopup()
                controller.beginTileDrag(frame: frame, translation: translation)
                pendingOrder = preferences.trayOrder
                draggedItem = item
            }
            controller.updateTileDrag()
            let frames = currentFrames().filter { $0.key != item }
            guard let target = frames.min(by: { abs($0.value.midX - point.x) < abs($1.value.midX - point.x) }),
                  target.value.insetBy(dx: -2, dy: -12).contains(point) else { return }
            let order = TrayItem.moving(item, relativeTo: target.key, after: point.x >= target.value.midX,
                                       in: pendingOrder ?? preferences.trayOrder)
            if order != pendingOrder {
                withAnimation(.easeInOut(duration: 0.16)) { pendingOrder = order }
            }
        }, ended: { point in
            if currentFrames().values.contains(where: { $0.insetBy(dx: -3, dy: -12).contains(point) }),
               let pendingOrder {
                preferences.rememberTrayOrder(pendingOrder)
            }
            cancelDrag()
        })
    }

    private func currentFrames() -> [TrayItem: CGRect] {
        var frames: [TrayItem: CGRect] = [:]
        for item in visibleItems {
            guard let button = buttons[item], let window = button.window else { continue }
            frames[item] = window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        return frames
    }

    private func cancelDrag() {
        controller.endTileDrag()
        withAnimation(.easeInOut(duration: 0.16)) {
            draggedItem = nil
            pendingOrder = nil
        }
    }

    private func popup(for item: TrayItem) -> Popup {
        switch item {
        case .aiLimits: return .aiLimits
        case .wifi: return .wifi
        case .sound: return .volume
        case .battery: return .battery
        case .clock: return .calendar
        case .settings: return .settings
        case .inputLanguage: preconditionFailure("Input language uses its native menu")
        }
    }

    private func width(for item: TrayItem) -> CGFloat {
        switch item {
        case .aiLimits: return 56
        case .inputLanguage: return 38
        case .battery: return 32
        case .clock: return 88
        default: return 28
        }
    }

    private func title(for item: TrayItem) -> String {
        switch item {
        case .aiLimits: return "AI usage limits, percent remaining"
        case .wifi: return "Wi-Fi networks"
        case .sound: return "Volume"
        case .clock: return "Date and calendar"
        case .settings: return "Macbar settings"
        default: return item.control?.title ?? ""
        }
    }

    private func help(for item: TrayItem) -> String {
        item == .battery ? battery.state?.summary ?? "Battery" : title(for: item)
    }

    @ViewBuilder private func label(for item: TrayItem) -> some View {
        switch item {
        case .aiLimits: AILimitsTrayLabel(limits: aiLimits)
        case .wifi: Image(systemName: wifi.symbol).font(.system(size: 14))
        case .sound: Image(systemName: audio.symbol).font(.system(size: 14))
        case .battery:
            if let state = battery.state {
                Image(systemName: state.symbol).font(.system(size: 17))
                    .foregroundStyle(state.isLow ? Color.red : state.isCharging ? Color.green : Color.primary)
            }
        case .clock:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .trailing, spacing: 3) {
                    Text(context.date, format: .dateTime.hour().minute()).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    Text(context.date, format: .dateTime.day().month(.twoDigits).year()).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 4).frame(height: 44)
            }
        case .settings: Image(systemName: "gearshape").font(.system(size: 15))
        case .inputLanguage: EmptyView()
        }
    }
}
