import AppKit
import ApplicationServices

struct TaskbarWindow: Identifiable, Equatable {
    let id: UUID
    let bundleID: String
    let processID: pid_t
    let title: String
    let isMinimized: Bool
    var isFocused: Bool
    var element: AXUIElement? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.bundleID == rhs.bundleID && lhs.processID == rhs.processID &&
        lhs.title == rhs.title && lhs.isMinimized == rhs.isMinimized && lhs.isFocused == rhs.isFocused
    }
}

enum SpecialTile: String {
    case appleMusic = "com.apple.Music"

    var width: CGFloat { 122 }
}

struct TaskbarTile: Identifiable {
    let app: ApplicationItem
    let window: TaskbarWindow?
    var special: SpecialTile? { SpecialTile(rawValue: app.id) }
    var id: String { window.map { "window:\($0.id)" } ?? "app:\(app.id)" }
    var title: String {
        guard let title = window?.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return app.name }
        return title
    }

    func showsTitle(mode: TaskbarMode, isRunning: Bool) -> Bool {
        special == nil && (window != nil || (mode == .windows && isRunning))
    }

    static func make(apps: [ApplicationItem], windows: [TaskbarWindow], mode: TaskbarMode, separateMultipleWindows: Bool = false) -> [Self] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.id).inserted }.flatMap { app -> [Self] in
            let appWindows = windows.filter { $0.bundleID == app.id }
            if SpecialTile(rawValue: app.id) != nil { return [Self(app: app, window: nil)] }
            let matches = mode == .windows || (separateMultipleWindows && appWindows.count >= 2) ? appWindows : []
            // A pinned app is replaced by its windows, so it doesn't gain a duplicate launcher.
            return matches.isEmpty ? [Self(app: app, window: nil)] : matches.map { Self(app: app, window: $0) }
        }
    }
}

/// A pair occupies one slot in the strip so overflow cannot split its two halves.
struct TaskbarStripItem: Identifiable {
    let tiles: [TaskbarTile]
    let groupID: UUID?
    var id: String { groupID.map { "group:\($0)" } ?? tiles[0].id }
    var isGroup: Bool { groupID != nil }
    var title: String { tiles.map(\.title).joined(separator: " + ") }

    func isActive(activeID: String?) -> Bool {
        tiles.contains { $0.app.id == activeID && ($0.window?.isFocused ?? true) }
    }

    static func make(tiles: [TaskbarTile], groups: [WindowGroup]) -> [TaskbarStripItem] {
        var consumed = Set<String>()
        var result: [TaskbarStripItem] = []
        for tile in tiles where !consumed.contains(tile.id) {
            if let group = groups.first(where: { $0.contains(tile) }) {
                let matches = tiles.filter { group.contains($0) && !consumed.contains($0.id) }
                if matches.count == 2 {
                    consumed.formUnion(matches.map(\.id))
                    result.append(TaskbarStripItem(tiles: matches, groupID: group.id))
                    continue
                }
            }
            consumed.insert(tile.id)
            result.append(TaskbarStripItem(tiles: [tile], groupID: nil))
        }
        return result
    }

    static func moving(_ sourceID: String, relativeTo targetID: String, after: Bool,
                       in items: [TaskbarStripItem]) -> [TaskbarStripItem] {
        guard sourceID != targetID, let source = items.firstIndex(where: { $0.id == sourceID }),
              items.contains(where: { $0.id == targetID }) else { return items }
        var result = items
        let item = result.remove(at: source)
        guard let target = result.firstIndex(where: { $0.id == targetID }) else { return items }
        result.insert(item, at: target + (after ? 1 : 0))
        return result
    }
}

/// App order is persisted separately; live window identities are session-only.
/// Remember identity rather than title so renames and duplicate titles stay put.
struct TaskbarTileOrder {
    private struct Entry: Equatable {
        let id: String
        let appID: String
    }
    private var entries: [Entry] = []

    func ordered(_ tiles: [TaskbarTile]) -> [TaskbarTile] {
        guard !entries.isEmpty else { return tiles }
        let previousIDs = Set(entries.map(\.id))
        let survivingApps = Set(tiles.filter { previousIDs.contains($0.id) }.map { $0.app.id })
        var remaining = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [TaskbarTile] = []
        for entry in entries {
            if let tile = remaining.removeValue(forKey: entry.id) {
                result.append(tile)
            } else if !survivingApps.contains(entry.appID) {
                // Replace an app launcher with its windows (or vice versa) in place.
                for tile in tiles where tile.app.id == entry.appID {
                    if let replacement = remaining.removeValue(forKey: tile.id) { result.append(replacement) }
                }
            }
        }
        for tile in tiles {
            guard let newTile = remaining.removeValue(forKey: tile.id) else { continue }
            if let sibling = result.lastIndex(where: { $0.app.id == tile.app.id }) {
                result.insert(newTile, at: sibling + 1)
            } else { result.append(newTile) }
        }
        return result
    }

    mutating func remember(_ tiles: [TaskbarTile]) {
        let next = tiles.map { Entry(id: $0.id, appID: $0.app.id) }
        if entries != next { entries = next }
    }

    static func moving(_ id: String, relativeTo targetID: String, after: Bool,
                       in tiles: [TaskbarTile]) -> [TaskbarTile] {
        guard id != targetID, let source = tiles.firstIndex(where: { $0.id == id }),
              tiles.contains(where: { $0.id == targetID }) else { return tiles }
        var result = tiles
        let tile = result.remove(at: source)
        guard let target = result.firstIndex(where: { $0.id == targetID }) else { return tiles }
        result.insert(tile, at: target + (after ? 1 : 0))
        return result
    }
}

/// Spend the full strip before resorting to overflow: move left, shorten search,
/// cap long titles evenly, then use icons when even abbreviated labels won't fit.
struct TaskbarStripLayout {
    static let trayWidth: CGFloat = 244
    let centered: Bool
    let showsSearchLabel: Bool
    let availableWidth: CGFloat
    let tileWidths: [CGFloat]
    let memberWidths: [[CGFloat]]
    let capacity: Int
    private let searchVisible: Bool
    private let missionControlVisible: Bool

    var headerWidth: CGFloat {
        Self.headerWidth(search: searchVisible, searchLabel: showsSearchLabel, missionControl: missionControlVisible)
    }
    var tilesWidth: CGFloat { tileWidths.reduce(0, +) + CGFloat(max(0, capacity - 1)) * 4 }

    init(screenWidth: CGFloat, alignment: TaskbarAlignment, preferredWidths: [CGFloat], mode: TaskbarMode,
         titledTiles: [Bool]? = nil, iconWidths: [CGFloat]? = nil,
         memberPreferredWidths: [[CGFloat]]? = nil, memberTitledTiles: [[Bool]]? = nil,
         memberIconWidths: [[CGFloat]]? = nil,
         trayWidth: CGFloat = Self.trayWidth, showSearch: Bool = true, showMissionControl: Bool = true) {
        searchVisible = showSearch
        missionControlVisible = showMissionControl
        let count = preferredWidths.count
        let spacing: CGFloat = 4
        let gaps = CGFloat(max(0, count - 1)) * spacing
        let titles = titledTiles?.count == count ? titledTiles! : Array(repeating: mode == .windows, count: count)
        let icons = iconWidths?.count == count ? iconWidths! : Array(repeating: CGFloat(44), count: count)
        let hasMembers = memberPreferredWidths?.count == count && memberTitledTiles?.count == count &&
            (0..<count).allSatisfy { !memberPreferredWidths![$0].isEmpty && memberPreferredWidths![$0].count == memberTitledTiles![$0].count }
        let memberTitles = hasMembers ? memberTitledTiles! : titles.map { [$0] }
        let validMemberIcons = hasMembers && memberIconWidths?.count == count &&
            (0..<count).allSatisfy { memberIconWidths![$0].count == memberTitles[$0].count }
        let memberIcons = validMemberIcons ? memberIconWidths! : (hasMembers ? memberTitles.map { Array(repeating: CGFloat(44), count: $0.count) } : icons.map { [$0] })
        let preferred = hasMembers ? memberPreferredWidths! : preferredWidths.map { [$0] }
        let memberDesired = (0..<count).map { index in
            preferred[index].indices.map { member in
                memberTitles[index][member] ? min(200, max(88, preferred[index][member])) : memberIcons[index][member]
            }
        }
        let widths = memberDesired.map { $0.reduce(0, +) }
        let desired = widths.reduce(0, +) + gaps
        let initialHeader = Self.headerWidth(search: showSearch, searchLabel: screenWidth >= 1100, missionControl: showMissionControl)
        let centeredBudget = max(0, screenWidth - trayWidth * 2 - 24)
        centered = alignment == .center && initialHeader + desired <= centeredBudget
        availableWidth = max(0, screenWidth - (centered ? trayWidth * 2 + 24 : trayWidth + 24))
        let minimumWidths = (0..<count).map { index in
            memberTitles[index].indices.reduce(CGFloat(0)) { $0 + (memberTitles[index][$1] ? 64 : memberIcons[index][$1]) }
        }
        let readableMinimum = minimumWidths.reduce(0, +)
        showsSearchLabel = showSearch && screenWidth >= 1100 && initialHeader + readableMinimum + gaps <= availableWidth
        let budget = max(0, availableWidth - Self.headerWidth(search: showSearch, searchLabel: showsSearchLabel, missionControl: showMissionControl))

        if desired <= budget {
            capacity = count
            tileWidths = widths
            memberWidths = memberDesired
        } else if readableMinimum + gaps <= budget {
            // Water filling: short names keep their natural width, longer ones
            // share the remaining room instead of wasting it on uniform tiles.
            var low: CGFloat = 64
            var high: CGFloat = 200
            for _ in 0..<24 {
                let cap = (low + high) / 2
                let capped = (0..<count).reduce(CGFloat(0)) { total, index in
                    total + memberDesired[index].indices.reduce(CGFloat(0)) { sum, member in
                        sum + (memberTitles[index][member] ? min(memberDesired[index][member], cap) : memberDesired[index][member])
                    }
                }
                if capped + gaps <= budget { low = cap }
                else { high = cap }
            }
            capacity = count
            let cappedMembers = (0..<count).map { index in
                memberDesired[index].indices.map { member in
                    memberTitles[index][member] ? min(memberDesired[index][member], low) : memberDesired[index][member]
                }
            }
            memberWidths = cappedMembers
            tileWidths = cappedMembers.map { $0.reduce(0, +) }
        } else {
            let allIconsFit = icons.reduce(0, +) + gaps <= budget
            let iconBudget = max(0, budget - (allIconsFit ? 0 : 38))
            var visible: [CGFloat] = []
            var used: CGFloat = 0
            for icon in icons {
                let next = used + (visible.isEmpty ? 0 : spacing) + icon
                guard next <= iconBudget else { break }
                visible.append(icon)
                used = next
            }
            capacity = visible.count
            tileWidths = visible
            memberWidths = Array(memberIcons.prefix(visible.count))
        }
    }

    private static func headerWidth(search: Bool, searchLabel: Bool, missionControl: Bool) -> CGFloat {
        guard search || missionControl else { return 0 }
        return (search ? (searchLabel ? 115 : 34) : 0) + (missionControl ? 40 : 0)
            + (search && missionControl ? 4 : 0) + 23
    }
}
