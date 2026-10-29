import SwiftUI

struct TaskbarView: View {
    @ObservedObject var controller: TaskbarController
    @ObservedObject var applications: ApplicationStore
    @ObservedObject var preferences: Preferences
    @ObservedObject var audio: AudioStore
    @ObservedObject var battery: BatteryStore
    @ObservedObject var cpu: CPUStore
    @ObservedObject var wifi: WiFiStore
    @ObservedObject var keyboard: KeyboardInputStore
    @ObservedObject var aiLimits: AILimitsStore
    @ObservedObject var windowTiles: TaskbarWindowStore
    @ObservedObject var windowGroups: WindowGroupStore
    @ObservedObject var music: AppleMusicStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var windowTileOrder = TaskbarTileOrder()
    @State private var draggedTileID: String?
    @State private var dragOrder: TaskbarTileOrder?
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var startHovered = false

    var body: some View {
        GeometryReader { geometry in
            let sideWidth = preferences.trayWidth(hasBattery: battery.state != nil) + 15
            let apps = preferences.orderedTaskbarApps(applications.pinnedApps + applications.unpinnedRunningApps)
            let baseTiles = TaskbarTile.make(apps: apps, windows: windowTiles.windows, mode: preferences.taskbarMode, separateMultipleWindows: preferences.separateMultipleWindows)
            let arrangedTiles = preferences.usesWindowTiles ? windowTileOrder.ordered(baseTiles) : baseTiles
            let orderedTiles = dragOrder?.ordered(arrangedTiles) ?? arrangedTiles
            let tiles = groupedTogether(orderedTiles)
            let items = TaskbarStripItem.make(tiles: tiles, groups: windowGroups.groups)
            let layout = TaskbarStripLayout(screenWidth: geometry.size.width, alignment: preferences.alignment,
                                           preferredWidths: items.map { item in
                (item.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 61
            }, mode: preferences.taskbarMode,
                titledTiles: items.map { !$0.isGroup && $0.tiles[0].showsTitle(mode: preferences.taskbarMode, isRunning: applications.isRunning($0.tiles[0].app.id)) },
                iconWidths: items.map { $0.tiles.reduce(CGFloat(0)) { $0 + ($1.special?.width ?? 44) } },
                memberPreferredWidths: items.map { item in item.tiles.map { tile in
                    (tile.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 61
                } },
                memberTitledTiles: items.map { item in item.tiles.map { tile in
                    tile.showsTitle(mode: preferences.taskbarMode, isRunning: applications.isRunning(tile.app.id))
                } }, memberIconWidths: items.map { $0.tiles.map { $0.special?.width ?? 44 } }, trayWidth: sideWidth,
                showSearch: preferences.shows(.search), showMissionControl: preferences.shows(.missionControl), showStart: preferences.shows(.start))
            ZStack {
                GlassBackground(material: .hudWindow)
                (colorScheme == .dark ? Color(red: 0.06, green: 0.08, blue: 0.13).opacity(0.62) : Color(red: 0.90, green: 0.94, blue: 1).opacity(0.62))
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        taskbarSeparator
                        tray
                    }
                    .frame(width: sideWidth, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                HStack(spacing: 4) {
                    if preferences.shows(.start) {
                        Button { controller.toggle(.start) } label: {
                            HStack(spacing: 7) {
                                StartGlyph(size: 17)
                                Text("Start").font(.system(size: 12, weight: .medium))
                            }.frame(width: 74, height: 40)
                        }
                        .buttonStyle(TileButtonStyle(selected: controller.popup == .start))
                        .overlay { TileHoverGlow(hovered: startHovered) }
                        .background(AppIconHoverAnchor(resolved: { _ in }, hoverChanged: { inside, _ in startHovered = inside }))
                        .animation(.easeOut(duration: 0.14), value: startHovered)
                        .help("Start — apps, places, and quick notes")
                        .accessibilityLabel("Start")
                        .accessibilityIdentifier("taskbar.start")
                    }
                    if preferences.shows(.search) {
                    Button { controller.toggle(.launcher) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium))
                            if layout.showsSearchLabel { Text("Search").font(.system(size: 12)).foregroundStyle(.secondary) }
                        }
                        .frame(width: layout.showsSearchLabel ? 115 : 34, height: 32)
                        .background(.primary.opacity(colorScheme == .dark ? 0.08 : 0.045), in: Capsule())
                        .overlay { Capsule().strokeBorder(.primary.opacity(0.07)) }
                    }
                    .buttonStyle(.plain)
                    .help("Search applications")
                    .accessibilityLabel("Search applications")
                    }

                    if preferences.shows(.missionControl) {
                    Button { controller.openMissionControl() } label: {
                        Image(systemName: "rectangle.on.rectangle").font(.system(size: 19, weight: .regular)).frame(width: 40, height: 44)
                    }
                    .buttonStyle(TileButtonStyle())
                    .help("Mission Control")
                    .accessibilityLabel("Mission Control")
                    }

                    if preferences.shows(.start) || preferences.shows(.search) || preferences.shows(.missionControl) {
                    taskbarSeparator
                    }

                    ForEach(Array(items.prefix(layout.capacity).enumerated()), id: \.element.id) { index, item in
                        let groupActive = item.isGroup && item.isActive(activeID: applications.activeID)
                        HStack(spacing: 0) {
                            ForEach(Array(item.tiles.enumerated()), id: \.element.id) { memberIndex, tile in
                                TaskbarAppButton(tile: tile, width: tile.special == nil ? layout.memberWidths[index][memberIndex] : 44,
                                                 applications: applications, preferences: preferences,
                                                 artwork: tile.special == .appleMusic && music.playing == true ? music.artwork : nil,
                                                 grouped: item.isGroup, groupActive: groupActive,
                                                 ungroup: { if let group = windowGroups.group(for: tile) { windowGroups.ungroup(group) } },
                                                 canMoveLeft: index > 0, canMoveRight: index < items.count - 1,
                                                 hover: { inside, frame in controller.hoverApplication(tile.app, inside: inside, frame: frame) },
                                                 dragChanged: { point, translation, frame in
                                                     if draggedTileID == nil {
                                                         guard let frame else { return }
                                                         controller.dismissPopup()
                                                         // The icon is the drag handle, but the whole strip item moves together.
                                                         let dragFrame = CGRect(x: frame.minX - layout.memberWidths[index].prefix(memberIndex).reduce(0, +),
                                                                                y: frame.minY, width: layout.tileWidths[index], height: frame.height)
                                                         controller.beginTileDrag(frame: dragFrame, translation: translation)
                                                         var order = TaskbarTileOrder()
                                                         order.remember(tiles)
                                                         dragOrder = order
                                                         draggedTileID = item.id
                                                     }
                                                     controller.updateTileDrag()
                                                     if let target = target(at: point, excluding: item.id) {
                                                         let reordered = TaskbarStripItem.moving(item.id, relativeTo: target.id, after: target.after, in: items)
                                                         withAnimation(.easeInOut(duration: 0.16)) { dragOrder?.remember(reordered.flatMap(\.tiles)) }
                                                     }
                                                 },
                                                 dragEnded: { point in
                                                     if tileFrames.values.contains(where: { $0.insetBy(dx: -6, dy: -10).contains(point) }) {
                                                         commitOrder(dragOrder?.ordered(arrangedTiles) ?? tiles)
                                                     }
                                                     controller.endTileDrag()
                                                     withAnimation(.easeInOut(duration: 0.16)) {
                                                         draggedTileID = nil
                                                         dragOrder = nil
                                                     }
                                                 },
                                                 moveBy: { offset in move(item.id, relativeTo: items[index + offset].id, after: offset > 0, items: items) },
                                                 action: { controller.activate(tile) })
                                if tile.special == .appleMusic {
                                    MusicTileControls(music: music, running: applications.isRunning(tile.app.id))
                                }
                            }
                        }
                        .background {
                            if item.isGroup || item.tiles.first?.special != nil {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.primary.opacity(groupActive ? (colorScheme == .dark ? 0.17 : 0.12) : (colorScheme == .dark ? 0.10 : 0.07)))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(.primary.opacity(groupActive ? (colorScheme == .dark ? 0.28 : 0.22) : (colorScheme == .dark ? 0.16 : 0.12)), lineWidth: 1)
                                    }
                                    .padding(.vertical, 3)
                            }
                        }
                        .overlay(alignment: .leading) {
                            if item.isGroup {
                                Rectangle().fill(.primary.opacity(0.15)).frame(width: 1, height: 22)
                                    .offset(x: layout.memberWidths[index][0] - 0.5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if groupActive && !item.tiles.enumerated().contains(where: { memberIndex, tile in
                                tile.showsTitle(mode: preferences.taskbarMode, isRunning: applications.isRunning(tile.app.id)) &&
                                    layout.memberWidths[index][memberIndex] >= 64
                            }) {
                                Capsule().fill(Color.accentColor).frame(width: 22, height: 3)
                                    .padding(.bottom, 3).allowsHitTesting(false)
                            }
                        }
                        .animation(.easeOut(duration: 0.16), value: groupActive)
                        .opacity(draggedTileID == item.id ? 0 : 1)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: TaskbarTileFramesKey.self,
                                    value: [item.id: proxy.frame(in: .named("taskbarTiles"))])
                            }
                        }
                    }
                    if items.count > layout.capacity {
                        Menu {
                            ForEach(Array(items.dropFirst(layout.capacity))) { item in
                                ForEach(item.tiles) { tile in
                                    Button { controller.activate(tile) } label: { Label { Text(tile.title) } icon: { Image(nsImage: tile.app.icon) } }
                                    if tile.special == .appleMusic {
                                        Button("Previous track") { music.perform(.previous) }.disabled(!applications.isRunning(tile.app.id))
                                        Button(music.playbackTitle) { music.perform(.playPause) }.disabled(!applications.isRunning(tile.app.id))
                                        Button("Next track") { music.perform(.next) }.disabled(!applications.isRunning(tile.app.id))
                                    }
                                }
                            }
                            Divider()
                            Menu("Arrange tiles") {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    Menu(item.title) {
                                        Button("Move to Start") { if let first = items.first { move(item.id, relativeTo: first.id, after: false, items: items) } }
                                            .disabled(index == 0)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 17)).frame(width: 34, height: 44)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(preferences.usesWindowTiles ? "More windows and applications" : "More applications")
                        .accessibilityLabel(preferences.usesWindowTiles ? "More windows and applications" : "More applications")
                    }
                }
                .frame(width: layout.availableWidth, alignment: layout.centered ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: layout.centered ? .center : .leading)
                .padding(.horizontal, 12)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Text("Show on Taskbar")
                Divider()
                ForEach(TaskbarControl.allCases) { control in
                    Toggle(control.title, isOn: Binding(get: { preferences.shows(control) },
                                                       set: { preferences.setVisible($0, for: control) }))
                }
            }
            .coordinateSpace(name: "taskbarTiles")
            .onPreferenceChange(TaskbarTileFramesKey.self) { tileFrames = $0 }
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(colorScheme == .dark ? 0.20 : 0.80)).frame(height: 1) }
            .onChange(of: items.map(\.id), initial: true) { _, _ in
                if dragOrder == nil && preferences.usesWindowTiles { windowTileOrder.remember(tiles) }
                if let draggedTileID, !items.prefix(layout.capacity).contains(where: { $0.id == draggedTileID }) {
                    controller.endTileDrag()
                    self.draggedTileID = nil
                    dragOrder = nil
                }
            }
        }
        .alert("Unable to control Music", isPresented: Binding(get: { music.error != nil }, set: { if !$0 { music.error = nil } })) {
            Button("OK") { music.error = nil }
        } message: { Text(music.error ?? "") }
        .alert("Unable to arrange windows", isPresented: Binding(get: { windowGroups.error != nil }, set: { if !$0 { windowGroups.error = nil } })) {
            Button("OK") { windowGroups.error = nil }
        } message: { Text(windowGroups.error ?? "") }
        .alert("Unable to open application", isPresented: Binding(get: { applications.launchError != nil }, set: { if !$0 { applications.launchError = nil } })) {
            Button("OK") { applications.launchError = nil }
        } message: { Text(applications.launchError ?? "") }
        .alert("Unable to complete action", isPresented: Binding(get: { applications.actionError != nil }, set: { if !$0 { applications.actionError = nil } })) {
            Button("OK") { applications.actionError = nil }
        } message: { Text(applications.actionError ?? "") }
    }

    private func groupedTogether(_ tiles: [TaskbarTile]) -> [TaskbarTile] {
        var result = tiles
        for group in windowGroups.groups {
            let indices = result.indices.filter { group.contains(result[$0]) }
            guard indices.count == 2, indices[1] != indices[0] + 1 else { continue }
            let second = result.remove(at: indices[1])
            result.insert(second, at: indices[0] + 1)
        }
        return result
    }

    private var taskbarSeparator: some View {
        Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 25).padding(.horizontal, 7)
    }

    private func target(at point: CGPoint, excluding source: String) -> TaskbarDropTarget? {
        guard let nearest = tileFrames.filter({ $0.key != source }).min(by: { abs($0.value.midX - point.x) < abs($1.value.midX - point.x) }),
              nearest.value.insetBy(dx: -6, dy: -10).contains(point) else { return nil }
        return TaskbarDropTarget(id: nearest.key, after: point.x >= nearest.value.midX)
    }

    private func move(_ source: String, relativeTo target: String, after: Bool, items: [TaskbarStripItem]) {
        let reordered = TaskbarStripItem.moving(source, relativeTo: target, after: after, in: items)
        guard reordered.map(\.id) != items.map(\.id) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            commitOrder(reordered.flatMap(\.tiles))
        }
    }

    private func commitOrder(_ tiles: [TaskbarTile]) {
        if preferences.usesWindowTiles { windowTileOrder.remember(tiles) }
        preferences.rememberTaskbarOrder(tiles.map { $0.app.id })
    }

    private var tray: some View {
        TaskbarTrayView(controller: controller, preferences: preferences, audio: audio, battery: battery, cpu: cpu,
                        wifi: wifi, keyboard: keyboard, aiLimits: aiLimits)
    }
}

private struct TaskbarAppButton: View {
    let tile: TaskbarTile
    let width: CGFloat
    @ObservedObject var applications: ApplicationStore
    @ObservedObject var preferences: Preferences
    let artwork: NSImage?
    let grouped: Bool
    let groupActive: Bool
    let ungroup: () -> Void
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let hover: (Bool, CGRect) -> Void
    let dragChanged: (CGPoint, CGSize, CGRect?) -> Void
    let dragEnded: (CGPoint) -> Void
    let moveBy: (Int) -> Void
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false
    @State private var anchorView: NSView?
    @State private var suppressClick = false

    private var item: ApplicationItem { tile.app }
    private var showsTitle: Bool { tile.showsTitle(mode: preferences.taskbarMode, isRunning: applications.isRunning(item.id)) && width >= 64 }
    private var compressed: Bool { width < 88 }
    private var active: Bool {
        applications.activeID == item.id && (tile.window?.isFocused ?? true)
    }
    var body: some View {
        Button { if !suppressClick { action() } } label: {
            Group {
                if showsTitle {
                    HStack(spacing: compressed ? 5 : 9) {
                        Image(nsImage: item.icon).resizable().interpolation(.high)
                            .frame(width: compressed ? 24 : preferences.compact ? 28 : 32,
                                   height: compressed ? 24 : preferences.compact ? 28 : 32)
                            .fixedSize()
                        Text(tile.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(tile.window?.isMinimized == true ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, compressed ? 8 : 10)
                    .frame(width: width, height: preferences.compact ? 42 : 50)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                } else {
                    VStack(spacing: 1) {
                        Image(nsImage: artwork ?? item.icon).resizable().interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: grouped ? 28 : preferences.compact ? 30 : 34, height: grouped ? 28 : preferences.compact ? 30 : 34)
                            .clipShape(RoundedRectangle(cornerRadius: artwork == nil ? 0 : 5, style: .continuous))
                        if !grouped && preferences.taskbarMode == .icons && preferences.showAppLabels {
                            Text(item.name).font(.system(size: 8)).lineLimit(1).frame(width: 44)
                        }
                    }
                    .frame(width: 44, height: preferences.compact ? 42 : 50)
                    .overlay(alignment: .bottom) {
                        indicator.padding(.bottom, 2)
                    }
                }
            }
        }
        .buttonStyle(TileButtonStyle(selected: active && !grouped, showsBackground: !grouped))
        .overlay { TileHoverGlow(hovered: hovered) }
        .background(AppIconHoverAnchor(resolved: { anchorView = $0 }, hoverChanged: { inside, frame in
            hovered = inside
            if tile.window == nil { hover(inside, frame) }
        }))
        .highPriorityGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("taskbarTiles"))
            .onChanged { value in
                suppressClick = true
                let frame = anchorView.flatMap { view in
                    view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)) }
                }
                dragChanged(value.location, value.translation, frame)
            }
            .onEnded { value in
                dragEnded(value.location)
                // Do not turn the mouse-up that completed a drag into app activation.
                DispatchQueue.main.async { suppressClick = false }
            })
        .animation(.easeOut(duration: 0.14), value: hovered)
        .animation(.easeOut(duration: 0.16), value: active)
        .help(tile.window == nil ? item.name : "\(tile.title) · \(item.name)")
        .accessibilityLabel(tile.window == nil ? item.name : "\(tile.title), \(item.name)")
        .accessibilityValue(grouped ? "Grouped" : active ? "Active" : tile.window?.isMinimized == true ? "Minimized" : applications.isRunning(item.id) ? "Running" : "Pinned")
        .contextMenu {
            if grouped { Button("Ungroup windows", action: ungroup); Divider() }
            ApplicationContextMenu(item: item, applications: applications, preferences: preferences, window: tile.window, open: action)
        }
        .accessibilityAction(named: "Move Left") { if canMoveLeft { moveBy(-1) } }
        .accessibilityAction(named: "Move Right") { if canMoveRight { moveBy(1) } }
    }

    private var indicator: some View {
        Capsule().fill(active && !grouped ? Color.accentColor : Color.primary.opacity(0.40))
            .frame(width: active && !grouped ? 17 : 5, height: 3)
            .opacity(applications.isRunning(item.id) && !(grouped && groupActive) ? 1 : 0)
    }
}

private struct TaskbarDropTarget {
    let id: String
    let after: Bool
}

private struct TaskbarTileFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct MusicTileControls: View {
    @ObservedObject var music: AppleMusicStore
    let running: Bool

    var body: some View {
        HStack(spacing: 0) {
            control("backward.end.fill", label: "Previous track", command: .previous)
            control(music.playbackSymbol, label: music.playbackTitle, command: .playPause)
            control("forward.end.fill", label: "Next track", command: .next)
        }
        .frame(width: 78)
        .disabled(!running)
    }

    private func control(_ symbol: String, label: String, command: AppleMusicStore.Command) -> some View {
        Button { music.perform(command) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}
