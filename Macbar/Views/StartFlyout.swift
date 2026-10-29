import SwiftUI
import AppKit

struct StartFlyout: View {
    @ObservedObject var applications: ApplicationStore
    @ObservedObject var preferences: Preferences
    @ObservedObject var controller: TaskbarController
    @State private var noteCopied = false
    @StateObject private var downloads = RecentDownloadsStore()

    private var returnApps: [ApplicationItem] {
        // Recent launches lead; running apps make this useful on a fresh session.
        var seen = Set<String>()
        return Array((applications.recentApps + applications.unpinnedRunningApps)
            .filter { seen.insert($0.id).inserted }.prefix(3))
    }

    var body: some View {
        FlyoutSurface {
            VStack(spacing: 0) {
                header.background(heightReader)
                ScrollView {
                    VStack(alignment: .leading, spacing: 23) {
                        favorites
                        if !returnApps.isEmpty { jumpBackIn }
                        places
                        recentDownloads
                        scratchpad
                    }
                    .padding(.horizontal, 26).padding(.top, 8).padding(.bottom, 24)
                    .background(heightReader)
                }
                .scrollIndicators(.hidden)
                footer.background(heightReader)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onPreferenceChange(StartHeightKey.self) { controller.fitStart(to: $0) }
        .task { await downloads.refresh() }
    }

    private var heightReader: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: StartHeightKey.self, value: geometry.size.height)
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            StartGlyph(size: 29)
                .frame(width: 49, height: 49)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting(at: context.date)).font(.system(size: 21, weight: .semibold))
                    Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button { controller.toggle(.launcher) } label: {
                Label("All apps", systemImage: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 31)
                    .background(.primary.opacity(0.045), in: Capsule())
            }
            .buttonStyle(TileButtonStyle(cornerRadius: 16))
            .accessibilityLabel("Browse and search all apps")
        }
        .padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 22)
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Favorites", detail: "Your taskbar pins")
            if applications.pinnedApps.isEmpty {
                Text("Pin an app from Search to make it a favorite here.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 15)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 5) {
                    ForEach(applications.pinnedApps) { item in
                        Button { controller.launch(item) } label: {
                            VStack(spacing: 7) {
                                Image(nsImage: item.icon).resizable().interpolation(.high).frame(width: 36, height: 36)
                                Text(item.name).font(.system(size: 10)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity).frame(height: 72)
                        }
                        .buttonStyle(TileButtonStyle())
                        .help(item.name)
                        .accessibilityLabel("Open \(item.name)")
                        .contextMenu {
                            ApplicationContextMenu(item: item, applications: applications, preferences: preferences) { controller.launch(item) }
                        }
                    }
                }
            }
        }
    }

    private var jumpBackIn: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Jump back in", detail: "Recent & running")
            HStack(spacing: 6) {
                ForEach(returnApps) { item in
                    Button { controller.launch(item) } label: {
                        HStack(spacing: 9) {
                            Image(nsImage: item.icon).resizable().frame(width: 29, height: 29)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(applications.isRunning(item.id) ? "Running" : "Recently opened")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(TileButtonStyle(cornerRadius: 10))
                    .help("Open \(item.name)")
                }
            }
        }
    }

    private var places: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Go somewhere", detail: "Folders within reach")
            HStack(spacing: 7) {
                ForEach([FinderDestination.home, .downloads, .documents, .applications], id: \.self) { destination in
                    Button { controller.openStartPlace(destination) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: destination.symbol).font(.system(size: 14)).foregroundStyle(Color.accentColor)
                            Text(destination.title).font(.system(size: 10, weight: .medium))
                        }
                        .frame(maxWidth: .infinity).frame(height: 39)
                        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(TileButtonStyle(cornerRadius: 9))
                    .help("Open \(destination.title) in Finder")
                }
            }
        }
    }

    private var scratchpad: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeading("A thought for later", detail: nil)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(preferences.startQuickNote, forType: .string)
                    noteCopied = true
                } label: {
                    Label(noteCopied ? "Copied" : "Copy", systemImage: noteCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10)).padding(.horizontal, 7).frame(height: 23)
                }
                .buttonStyle(TileButtonStyle())
                .disabled(preferences.startQuickNote.isEmpty)
                .accessibilityLabel("Copy quick note")
            }
            ZStack(alignment: .topLeading) {
                if preferences.startQuickNote.isEmpty {
                    Text("An idea, a reminder, a tiny plan…")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 13).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $preferences.startQuickNote)
                    .font(.system(size: 12)).scrollContentBackground(.hidden)
                    .padding(8).frame(height: 82)
                    .accessibilityLabel("Quick note")
                    .accessibilityIdentifier("start.quickNote")
            }
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.06)) }
            Text("Saved automatically on this Mac")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .onChange(of: preferences.startQuickNote) { _, _ in noteCopied = false }
    }

    private var recentDownloads: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent files in Downloads").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { controller.openStartPlace(.downloads) } label: {
                    Label("Open folder", systemImage: "arrow.up.forward")
                        .font(.system(size: 9)).padding(.horizontal, 7).frame(height: 23)
                }.buttonStyle(TileButtonStyle()).accessibilityLabel("Open Downloads folder")
            }
            if downloads.isLoading {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Looking for your latest files…").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            } else if let error = downloads.error {
                HStack {
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { Task { await downloads.refresh() } }.font(.system(size: 10))
                }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            } else if downloads.files.isEmpty {
                Text("Your next download will appear here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(downloads.files) { file in
                        HStack(spacing: 0) {
                            Button { controller.openDownload(file) } label: {
                                HStack(spacing: 8) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                                        .resizable().frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                        HStack(spacing: 5) {
                                            Text(file.date, style: .relative)
                                            Text("·")
                                            Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))
                                        }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(TileButtonStyle(cornerRadius: 9))
                            .help("Open \(file.name)").accessibilityLabel("Open \(file.name)")
                            .contextMenu {
                                Button("Open") { controller.openDownload(file) }
                                Button("Reveal in Finder") { controller.revealDownload(file) }
                            }
                            Button { controller.revealDownload(file) } label: {
                                Image(systemName: "folder").font(.system(size: 12)).frame(width: 28, height: 42)
                            }
                            .buttonStyle(TileButtonStyle())
                            .help("Reveal \(file.name) in Finder").accessibilityLabel("Reveal \(file.name) in Finder")
                        }
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            quickTool("Show desktop", symbol: "rectangle.bottomthird.inset.filled") { controller.showDesktop() }
            quickTool("Screenshot", symbol: "camera.viewfinder") {
                controller.openStartApplication("com.apple.screenshot.launcher", name: "Screenshot")
            }
            quickTool("Calculator", symbol: "plus.forwardslash.minus") {
                controller.openStartApplication("com.apple.calculator", name: "Calculator")
            }
            Spacer(minLength: 5)
            Button { controller.toggle(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 17)).frame(width: 34, height: 36)
            }
            .buttonStyle(TileButtonStyle())
            .help("Macbar settings").accessibilityLabel("Macbar settings")
        }
        .padding(.horizontal, 23).padding(.vertical, 13)
        .background(.primary.opacity(0.035))
        .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.06)).frame(height: 1) }
    }

    private func quickTool(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(title).font(.system(size: 9))
            }.frame(width: 88, height: 43)
        }
        .buttonStyle(TileButtonStyle())
        .help(title).accessibilityLabel(title)
    }

    private func sectionHeading(_ title: String, detail: String?) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold))
            if let detail {
                Spacer()
                Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func greeting(at date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

private struct StartHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}
