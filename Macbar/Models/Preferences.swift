import AppKit
import Combine

enum BarAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum TaskbarAlignment: String, CaseIterable, Identifiable {
    case left, center
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum TaskbarMode: String, CaseIterable, Identifiable {
    case icons, windows
    var id: String { rawValue }
    var title: String { self == .icons ? "App icons" : "Window titles" }
}

enum TaskbarControl: String, CaseIterable, Identifiable {
    case inputLanguage, wifi, sound, battery, clock, search, missionControl, aiLimits
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inputLanguage: return "Input Language"
        case .wifi: return "Wi-Fi"
        case .sound: return "Sound"
        case .battery: return "Battery"
        case .clock: return "Clock"
        case .search: return "Search"
        case .missionControl: return "Mission Control"
        case .aiLimits: return "AI Limits"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let defaultPins = [
        "com.apple.finder", "com.apple.Safari", "com.apple.mail",
        "com.apple.MobileSMS", "com.apple.iCal", "com.apple.Terminal"
    ]

    private let defaults: UserDefaults
    @Published var appearance: BarAppearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    @Published var alignment: TaskbarAlignment { didSet { defaults.set(alignment.rawValue, forKey: "alignment") } }
    @Published var taskbarMode: TaskbarMode { didSet { defaults.set(taskbarMode.rawValue, forKey: "taskbarMode") } }
    @Published var separateMultipleWindows: Bool { didSet { defaults.set(separateMultipleWindows, forKey: "separateMultipleWindows") } }
    var usesWindowTiles: Bool { taskbarMode == .windows || separateMultipleWindows }
    @Published var hideDockWhileRunning: Bool { didSet { defaults.set(hideDockWhileRunning, forKey: "hideDockWhileRunning") } }
    @Published var compact: Bool { didSet { defaults.set(compact, forKey: "compact") } }
    @Published var showAppLabels: Bool { didSet { defaults.set(showAppLabels, forKey: "showAppLabels") } }
    @Published var keepWindowsAboveTaskbar: Bool { didSet { defaults.set(keepWindowsAboveTaskbar, forKey: "keepWindowsAboveTaskbar") } }
    @Published var pinnedIDs: [String] { didSet { defaults.set(pinnedIDs, forKey: "pinnedIDs") } }
    @Published private(set) var taskbarAppOrder: [String] { didSet { defaults.set(taskbarAppOrder, forKey: "taskbarAppOrder") } }
    @Published private(set) var trayOrder: [TrayItem] { didSet { defaults.set(trayOrder.map(\.rawValue), forKey: "trayOrder") } }
    @Published private(set) var drawerItems: Set<String> { didSet { defaults.set(drawerItems.sorted(), forKey: "trayDrawerItems") } }
    @Published private(set) var hiddenControls: Set<String> { didSet { defaults.set(hiddenControls.sorted(), forKey: "hiddenTaskbarControls") } }

    // Keep the icons unchanged, with roughly half the original surrounding space.
    var barHeight: CGFloat { compact ? 46 : 54 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = BarAppearance(rawValue: defaults.string(forKey: "appearance") ?? "system") ?? .system
        alignment = TaskbarAlignment(rawValue: defaults.string(forKey: "alignment") ?? "center") ?? .center
        taskbarMode = TaskbarMode(rawValue: defaults.string(forKey: "taskbarMode") ?? "icons") ?? .icons
        separateMultipleWindows = defaults.bool(forKey: "separateMultipleWindows")
        hideDockWhileRunning = defaults.bool(forKey: "hideDockWhileRunning")
        compact = defaults.bool(forKey: "compact")
        showAppLabels = defaults.bool(forKey: "showAppLabels")
        keepWindowsAboveTaskbar = defaults.object(forKey: "keepWindowsAboveTaskbar") as? Bool ?? true
        pinnedIDs = defaults.stringArray(forKey: "pinnedIDs") ?? Self.defaultPins
        taskbarAppOrder = defaults.stringArray(forKey: "taskbarAppOrder") ?? []
        trayOrder = TrayItem.normalized(defaults.stringArray(forKey: "trayOrder") ?? [])
        drawerItems = Set((defaults.stringArray(forKey: "trayDrawerItems") ?? []).compactMap { TrayItem(rawValue: $0)?.rawValue })
        hiddenControls = Set(defaults.stringArray(forKey: "hiddenTaskbarControls") ?? [])
    }

    func shows(_ control: TaskbarControl) -> Bool { !hiddenControls.contains(control.rawValue) }

    func rememberTrayOrder(_ items: [TrayItem]) {
        let normalized = TrayItem.normalized(items.map(\.rawValue))
        if trayOrder != normalized { trayOrder = normalized }
    }

    func isInDrawer(_ item: TrayItem) -> Bool { drawerItems.contains(item.rawValue) }

    func setInDrawer(_ inDrawer: Bool, for item: TrayItem) {
        if inDrawer { drawerItems.insert(item.rawValue) }
        else { drawerItems.remove(item.rawValue) }
    }

    func setVisible(_ visible: Bool, for control: TaskbarControl) {
        if visible { hiddenControls.remove(control.rawValue) }
        else { hiddenControls.insert(control.rawValue) }
    }

    var trayWidth: CGFloat {
        trayWidth(hasBattery: true)
    }

    func trayWidth(hasBattery: Bool) -> CGFloat {
        let widths: [(TaskbarControl, CGFloat)] = [(.inputLanguage, 38), (.wifi, 28), (.sound, 28), (.clock, 88), (.aiLimits, 56)]
        let visible = widths.filter { shows($0.0) && !drawerItems.contains($0.0.rawValue) }
        let settingsWidth: CGFloat = isInDrawer(.settings) ? 0 : 30
        return 28 + settingsWidth + visible.reduce(0) { $0 + $1.1 + 2 } + (hasBattery && shows(.battery) && !isInDrawer(.battery) ? 34 : 0)
    }

    func togglePin(_ id: String) {
        if pinnedIDs.contains(id) { pinnedIDs.removeAll { $0 == id } }
        else { pinnedIDs.append(id) }
    }

    func orderedTaskbarApps(_ apps: [ApplicationItem]) -> [ApplicationItem] {
        let ranks = Dictionary(taskbarAppOrder.enumerated().map { ($0.element, $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        return apps.enumerated().sorted {
            let left = ranks[$0.element.id] ?? Int.max
            let right = ranks[$1.element.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    func rememberTaskbarOrder(_ appIDs: [String]) {
        var seen = Set<String>()
        let visible = appIDs.filter { seen.insert($0).inserted }
        var remaining = visible.makeIterator()
        // Preserve positions for apps that are temporarily closed or unpinned.
        var remembered = taskbarAppOrder.compactMap { seen.contains($0) ? remaining.next() : $0 }
        remembered.append(contentsOf: remaining)
        if taskbarAppOrder != remembered { taskbarAppOrder = remembered }
        let orderedPins = remembered.filter { pinnedIDs.contains($0) }
            + pinnedIDs.filter { !remembered.contains($0) }
        if pinnedIDs != orderedPins { pinnedIDs = orderedPins }
    }
}

enum BarGeometry {
    static func frame(on screen: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: height)
    }

    static func popupFrame(screen: CGRect, barHeight: CGFloat, size: CGSize, alignment: PopupAlignment) -> CGRect {
        let margin: CGFloat = 12
        let width = min(size.width, max(0, screen.width - margin * 2))
        let height = min(size.height, max(0, screen.height - barHeight - margin * 2))
        let x: CGFloat
        switch alignment {
        case .left: x = screen.minX + margin
        case .center: x = screen.midX - width / 2
        case .right: x = screen.maxX - width - margin
        }
        return CGRect(x: x, y: screen.minY + barHeight + margin, width: width, height: height)
    }
}

enum PopupAlignment { case left, center, right }
