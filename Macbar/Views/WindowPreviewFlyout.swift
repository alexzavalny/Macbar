import SwiftUI

struct WindowPreviewFlyout: View {
    let item: ApplicationItem
    @ObservedObject var previews: WindowPreviewStore
    let select: (WindowPreview) -> Void

    var body: some View {
        FlyoutSurface {
            VStack(alignment: .leading, spacing: WindowPreviewGeometry.spacing) {
                HStack(spacing: 8) {
                    Image(nsImage: item.icon).resizable().frame(width: 20, height: 20)
                    Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if !previews.windows.isEmpty {
                        Text("\(previews.windows.count) \(previews.windows.count == 1 ? "window" : "windows")")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(height: WindowPreviewGeometry.headerHeight)
                switch previews.state {
                case .idle, .loading:
                    message { ProgressView().controlSize(.small); Text("Loading windows…") }
                case .permissionRequired:
                    message {
                        Image(systemName: "rectangle.on.rectangle").font(.system(size: 25)).foregroundStyle(.secondary)
                        Text("Allow Screen Recording to see window previews.")
                        Button("Allow previews…") { previews.requestAccess() }.buttonStyle(.bordered)
                    }
                case .failed:
                    message {
                        Text("Couldn’t load window previews.")
                        Button("Try again") { previews.show(item) }.buttonStyle(.bordered)
                    }
                case .ready:
                    if previews.windows.isEmpty {
                        message { Text("No open windows on this desktop.") }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            cards.fixedSize()
                            ScrollView(.horizontal) { cards }
                                .frame(height: WindowPreviewGeometry.cardHeight + 16)
                        }
                    }
                }
            }.padding(WindowPreviewGeometry.padding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var cards: some View {
        HStack(spacing: WindowPreviewGeometry.spacing) {
            ForEach(previews.windows) { window in
                Button { select(window) } label: {
                    VStack(alignment: .leading, spacing: WindowPreviewGeometry.titleSpacing) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.05))
                            if let image = window.image {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: "macwindow").font(.system(size: 32)).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: WindowPreviewGeometry.thumbnailSize.width, height: WindowPreviewGeometry.thumbnailSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(window.title).font(.system(size: 11)).lineLimit(1)
                            .frame(width: WindowPreviewGeometry.thumbnailSize.width, height: WindowPreviewGeometry.titleHeight, alignment: .leading)
                    }.padding(WindowPreviewGeometry.cardPadding)
                }
                .buttonStyle(TileButtonStyle())
                .accessibilityLabel("Open \(window.title)")
                .help(window.title)
            }
        }
    }

    private func message<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12, content: content).font(.system(size: 12)).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// AppKit gives us the icon's actual screen bounds, including after alignment changes.
struct AppIconHoverAnchor: NSViewRepresentable {
    let resolved: (NSView) -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        DispatchQueue.main.async { resolved(view) }
        return view
    }
    func updateNSView(_ view: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
