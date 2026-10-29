import SwiftUI
import AppKit

struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = material
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

struct FlyoutSurface<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background {
                ZStack {
                    GlassBackground(material: .popover)
                    colorScheme == .dark ? Color.black.opacity(0.12) : Color.white.opacity(0.18)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(colorScheme == .dark ? 0.18 : 0.72)) }
    }
}

struct TileButtonStyle: ButtonStyle {
    var selected = false
    var cornerRadius: CGFloat = 7
    var showsBackground = true
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration, selected: selected, cornerRadius: cornerRadius, dark: colorScheme == .dark, showsBackground: showsBackground)
    }

    private struct TileBody: View {
        let configuration: Configuration
        let selected: Bool
        let cornerRadius: CGFloat
        let dark: Bool
        let showsBackground: Bool
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.white.opacity(showsBackground ? (configuration.isPressed ? (dark ? 0.06 : 0.30) : (hovered || selected) ? (dark ? 0.13 : 0.58) : 0) : 0))
                        .overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(showsBackground && (hovered || selected) ? 0.20 : 0)) }
                }
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.14), value: hovered)
                .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
        }
    }
}

struct StartGlyph: View {
    var size: CGFloat = 23
    var body: some View {
        let gap: CGFloat = 2.5
        let tile = (size - gap) / 2
        VStack(spacing: gap) {
            HStack(spacing: gap) { square(tile); square(tile) }
            HStack(spacing: gap) { square(tile); square(tile) }
        }
        .foregroundStyle(LinearGradient(colors: [Color(red: 0.19, green: 0.65, blue: 1), Color(red: 0.04, green: 0.35, blue: 0.94)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .shadow(color: .blue.opacity(0.18), radius: 3, y: 1)
    }
    private func square(_ size: CGFloat) -> some View { RoundedRectangle(cornerRadius: 1.4).frame(width: size, height: size) }
}

/// Shared by Start and application tiles, including in a nonactivating panel.
struct TileHoverGlow: View {
    let hovered: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill((colorScheme == .dark ? Color.white : Color.black).opacity(hovered ? (colorScheme == .dark ? 0.10 : 0.055) : 0))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder((colorScheme == .dark ? Color.white : Color.black).opacity(hovered ? (colorScheme == .dark ? 0.24 : 0.12) : 0), lineWidth: 1)
            }
            .shadow(color: (colorScheme == .dark ? Color.white : Color.black).opacity(hovered ? (colorScheme == .dark ? 0.12 : 0.08) : 0), radius: 5)
            .padding(2)
            .allowsHitTesting(false)
    }
}

struct ApplicationContextMenu: View {
    let item: ApplicationItem
    @ObservedObject var applications: ApplicationStore
    @ObservedObject var preferences: Preferences
    var window: TaskbarWindow? = nil
    let open: () -> Void

    var body: some View {
        Button("Open \(item.name)", action: open)
        if item.id == "com.apple.finder" {
            Divider()
            ForEach(FinderDestination.allCases, id: \.self) { destination in
                Button { applications.openFinderDestination(destination.url, name: destination.title, finder: item) } label: {
                    Label(destination.title, systemImage: destination.symbol)
                }
            }
        }
        Divider()
        Button(preferences.pinnedIDs.contains(item.id) ? "Unpin from taskbar" : "Pin to taskbar") { preferences.togglePin(item.id) }
        Button("Show in Finder") { applications.reveal(item) }
        if applications.isRunning(item.id) {
            Divider()
            Button("Close window") { applications.closeWindow(item, window: window) }
            Button("Quit \(item.name)") { applications.quit(item) }
            Button(role: .destructive) {
                applications.forceQuit(item, window: window)
            } label: {
                Text("Force Quit").foregroundStyle(.red)
            }
        }
    }
}

enum FinderDestination: CaseIterable {
    case home, desktop, documents, downloads, applications, pictures, movies, music

    var title: String {
        switch self {
        case .home: "Home"
        case .desktop: "Desktop"
        case .documents: "Documents"
        case .downloads: "Downloads"
        case .applications: "Applications"
        case .pictures: "Pictures"
        case .movies: "Movies"
        case .music: "Music"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .desktop: "desktopcomputer"
        case .documents: "doc.text"
        case .downloads: "arrow.down.circle"
        case .applications: "square.grid.2x2"
        case .pictures: "photo"
        case .movies: "film"
        case .music: "music.note"
        }
    }

    var url: URL {
        let manager = FileManager.default
        switch self {
        case .home: return manager.homeDirectoryForCurrentUser
        case .desktop: return manager.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        case .documents: return manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        case .downloads: return manager.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .applications: return manager.urls(for: .applicationDirectory, in: .localDomainMask)[0]
        case .pictures: return manager.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        case .movies: return manager.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        case .music: return manager.urls(for: .musicDirectory, in: .userDomainMask)[0]
        }
    }
}
