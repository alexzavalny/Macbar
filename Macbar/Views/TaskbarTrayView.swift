import SwiftUI

struct TaskbarTrayView: View {
    @ObservedObject var controller: TaskbarController
    @ObservedObject var preferences: Preferences
    @ObservedObject var audio: AudioStore
    @ObservedObject var battery: BatteryStore
    @ObservedObject var cpu: CPUStore
    @ObservedObject var wifi: WiFiStore
    @ObservedObject var keyboard: KeyboardInputStore
    @ObservedObject var aiLimits: AILimitsStore
    @State private var draggedItem: TrayItem?
    @State private var pendingOrder: [TrayItem]?
    @State private var buttons: [TrayItem: NSView] = [:]
    @State private var drawerButton: NSView?
    @State private var drawerContent: NSView?
    @State private var drawerOpen = false

    private var availableItems: [TrayItem] {
        (pendingOrder ?? preferences.trayOrder).filter {
            ($0.control.map(preferences.shows) ?? true) && ($0 != .battery || battery.state != nil)
        }
    }
    private var visibleItems: [TrayItem] { availableItems.filter { !preferences.isInDrawer($0) } }
    private var drawerItems: [TrayItem] { availableItems.filter { preferences.isInDrawer($0) } }

    var body: some View {
        HStack(spacing: 2) {
            Button {
                controller.dismissPopup()
                drawerOpen.toggle()
            } label: {
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 44)
            }
            .buttonStyle(TileButtonStyle(selected: drawerOpen))
            .help("Hidden tray icons")
            .accessibilityLabel("Hidden tray icons")
            .background(TrayFrameAnchor { drawerButton = $0 })
            .popover(isPresented: $drawerOpen, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hidden tray icons").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if drawerItems.isEmpty {
                        Text("Drag tray icons here to hide them.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(minWidth: 200, minHeight: 44, alignment: .leading)
                    } else {
                        HStack(spacing: 2) {
                            ForEach(drawerItems) { item in trayItem(item, inDrawer: true) }
                        }
                    }
                }
                .padding(12)
                .background(TrayFrameAnchor { drawerContent = $0 })
            }
            ForEach(visibleItems) { item in trayItem(item, inDrawer: false) }
        }
        .onDisappear { cancelDrag() }
    }

    private func trayItem(_ item: TrayItem, inDrawer: Bool) -> some View {
        Group {
            if item == .inputLanguage {
                KeyboardInputMenu(keyboard: keyboard, willOpen: { controller.dismissPopup() },
                                  dragActions: dragActions(for: item), register: { buttons[item] = $0 })
            } else {
                TrayButton(selected: item != .trash && controller.popup == popup(for: item),
                           accessibilityLabel: title(for: item),
                           accessibilityValue: item == .battery ? battery.state?.summary ?? "" : item == .cpu ? cpu.summary : "",
                           help: help(for: item), dragActions: dragActions(for: item),
                           register: { buttons[item] = $0 }, action: {
                    drawerOpen = false
                    if item == .trash { controller.openTrash() }
                    else { controller.toggle(popup(for: item)) }
                }) { label(for: item) }
            }
        }
        .frame(width: width(for: item), height: 44)
        .opacity(draggedItem == item ? 0 : 1)
        .contextMenu {
            if item == .trash {
                Button("Empty Trash…") { controller.emptyTrash() }
                Divider()
            }
            Button(inDrawer ? "Show on taskbar" : "Move to hidden icons") {
                preferences.setInDrawer(!inDrawer, for: item)
            }
        }
        .accessibilityActions {
            if item == .trash { Button("Empty Trash") { controller.emptyTrash() } }
        }
        .accessibilityAction(named: inDrawer ? "Show on taskbar" : "Move to hidden icons") {
            preferences.setInDrawer(!inDrawer, for: item)
        }
    }

    private func dragActions(for item: TrayItem) -> TrayDragActions {
        TrayDragActions(changed: { point, translation, frame in
            if draggedItem == nil {
                controller.dismissPopup()
                controller.beginTileDrag(frame: frame, translation: translation, sourceWindow: buttons[item]?.window)
                pendingOrder = preferences.trayOrder
                draggedItem = item
            }
            controller.updateTileDrag()
            // Reorder only within the same section; crossing sections is committed on drop.
            let frames = currentFrames().filter { $0.key != item && preferences.isInDrawer($0.key) == preferences.isInDrawer(item) }
            guard let target = frames.min(by: { abs($0.value.midX - point.x) < abs($1.value.midX - point.x) }),
                  target.value.insetBy(dx: -2, dy: -12).contains(point) else { return }
            let order = TrayItem.moving(item, relativeTo: target.key, after: point.x >= target.value.midX,
                                       in: pendingOrder ?? preferences.trayOrder)
            if order != pendingOrder {
                withAnimation(.easeInOut(duration: 0.16)) { pendingOrder = order }
            }
        }, ended: { point in
            let frames = currentFrames()
            let drawerFrame = screenFrame(drawerButton)
            let contentFrame = drawerOpen ? screenFrame(drawerContent) : nil
            let overChevron = drawerFrame?.insetBy(dx: -4, dy: -8).contains(point) ?? false
            let overDrawer = (overChevron && !preferences.isInDrawer(item))
                || (contentFrame?.insetBy(dx: -4, dy: -4).contains(point) ?? false)
            let trayFrames = frames.filter { !preferences.isInDrawer($0.key) }
            let overTray = trayFrames.values.contains { $0.insetBy(dx: -4, dy: -12).contains(point) }
            if overDrawer {
                preferences.setInDrawer(true, for: item)
                if let pendingOrder { preferences.rememberTrayOrder(pendingOrder) }
            } else if overTray || (overChevron && preferences.isInDrawer(item)) {
                if preferences.isInDrawer(item),
                   let target = trayFrames.min(by: { abs($0.value.midX - point.x) < abs($1.value.midX - point.x) }) {
                    preferences.rememberTrayOrder(TrayItem.moving(item, relativeTo: target.key,
                        after: point.x >= target.value.midX, in: pendingOrder ?? preferences.trayOrder))
                } else if let pendingOrder { preferences.rememberTrayOrder(pendingOrder) }
                preferences.setInDrawer(false, for: item)
            }
            cancelDrag()
        })
    }

    private func screenFrame(_ view: NSView?) -> CGRect? {
        guard let view, let window = view.window, window.isVisible else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func currentFrames() -> [TrayItem: CGRect] {
        var frames: [TrayItem: CGRect] = [:]
        for item in availableItems {
            if let frame = screenFrame(buttons[item]) { frames[item] = frame }
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
        case .cpu: return .cpu
        case .clock: return .calendar
        case .settings: return .settings
        case .inputLanguage, .trash: preconditionFailure("This control does not use a popup")
        }
    }

    private func width(for item: TrayItem) -> CGFloat {
        switch item {
        case .aiLimits: return 56
        case .inputLanguage: return 38
        case .battery: return 32
        case .cpu: return 58
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
        item == .battery ? battery.state?.summary ?? "Battery" : item == .cpu ? cpu.summary : item == .trash ? "Open Trash; right-click to empty" : title(for: item)
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
        case .cpu:
            HStack(spacing: 3) {
                CPUMeter(fraction: cpu.usage?.total)
                Text(cpu.percentageLabel).font(.system(size: 11, weight: .medium)).monospacedDigit()
            }
        case .clock:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .trailing, spacing: 3) {
                    Text(context.date, format: .dateTime.hour().minute()).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    Text(context.date, format: .dateTime.day().month(.twoDigits).year()).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 4).frame(height: 44)
            }
        case .trash: Image(systemName: "trash").font(.system(size: 15))
        case .settings: Image(systemName: "gearshape").font(.system(size: 15))
        case .inputLanguage: EmptyView()
        }
    }
}

private struct TrayFrameAnchor: NSViewRepresentable {
    let register: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { register(view) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

private struct CPUMeter: View {
    let fraction: Double?
    private let height: CGFloat = 22

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.10))
            LinearGradient(stops: [
                .init(color: .green, location: 0),
                .init(color: .green, location: 0.35),
                .init(color: .yellow, location: 0.55),
                .init(color: .yellow, location: 0.95),
                .init(color: .red, location: 0.95),
                .init(color: .red, location: 1)
            ], startPoint: .bottom, endPoint: .top)
            .mask(alignment: .bottom) {
                Rectangle().frame(height: height * CGFloat(min(max(fraction ?? 0, 0), 1)))
            }
        }
        .frame(width: 12, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.25), lineWidth: 1))
        .animation(.easeInOut(duration: 0.8), value: fraction)
    }
}
