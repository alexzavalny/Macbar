import SwiftUI

struct LauncherView: View {
    @ObservedObject var applications: ApplicationStore
    @ObservedObject var preferences: Preferences
    @ObservedObject var controller: TaskbarController
    @State private var query = ""
    @State private var showAll = false
    @FocusState private var searchFocused: Bool

    private var results: [ApplicationItem] {
        applications.installed.filter { ApplicationItem.matches($0.name, query: query) }
    }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        FlyoutSurface {
            VStack(spacing: 0) {
                searchField.padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 22)
                if searching || showAll {
                    allApplications
                } else {
                    home
                }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { searchFocused = true }
        }
        .alert("Unable to complete action", isPresented: Binding(get: { applications.actionError != nil }, set: { if !$0 { applications.actionError = nil } })) {
            Button("OK") { applications.actionError = nil }
        } message: { Text(applications.actionError ?? "") }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 15))
            TextField("Search your apps", text: $query)
                .textFieldStyle(.plain).font(.system(size: 14))
                .focused($searchFocused)
                .onSubmit { if let first = results.first { controller.launch(first) } }
                .accessibilityLabel("Search your apps")
            if !query.isEmpty {
                Button { query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(.background.opacity(0.66), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottom) {
            UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2)
                .fill(Color.accentColor).frame(height: 2).padding(.horizontal, 6)
        }
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.06)) }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Pinned").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button { showAll = true } label: {
                        HStack(spacing: 7) { Text("All apps"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                            .font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 14)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 6), spacing: 12) {
                    ForEach(applications.pinnedApps) { item in launcherTile(item) }
                }
                .frame(minHeight: 158, alignment: .top)

                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Text("Recently opened").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text("With Macbar").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    if applications.recentApps.isEmpty {
                        HStack(spacing: 13) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 25, weight: .light)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("A fresh start").font(.system(size: 12, weight: .medium))
                                Text("Apps you open here will be within easy reach.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                            ForEach(applications.recentApps) { item in
                                Button { controller.launch(item) } label: {
                                    HStack(spacing: 10) {
                                        Image(nsImage: item.icon).resizable().frame(width: 32, height: 32)
                                        Text(item.name).font(.system(size: 12)).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }.padding(8).frame(maxWidth: .infinity)
                                }.buttonStyle(TileButtonStyle())
                            }
                        }
                    }
                }.padding(.horizontal, 14)
            }
            .padding(.horizontal, 20).padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
    }

    private var allApplications: some View {
        VStack(spacing: 10) {
            HStack {
                Text(searching ? "Search results" : "All apps").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(results.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                if !searching {
                    Button { showAll = false } label: { Label("Back", systemImage: "chevron.left").font(.system(size: 11)) }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 14)
            if results.isEmpty {
                ContentUnavailableView.search(text: query).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(results) { item in
                            Button { controller.launch(item) } label: {
                                HStack(spacing: 13) {
                                    Image(nsImage: item.icon).resizable().frame(width: 34, height: 34)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name).font(.system(size: 13, weight: .medium))
                                        Text("Application").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if applications.isRunning(item.id) { Circle().fill(Color.accentColor).frame(width: 5, height: 5) }
                                    Image(systemName: "arrow.up.left").font(.system(size: 11)).foregroundStyle(.tertiary)
                                }.padding(.horizontal, 14).padding(.vertical, 7).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(TileButtonStyle())
                            .contextMenu { ApplicationContextMenu(item: item, applications: applications, preferences: preferences) { controller.launch(item) } }
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }.padding(.horizontal, 24).frame(maxHeight: .infinity).padding(.bottom, 18)
    }

    private func launcherTile(_ item: ApplicationItem) -> some View {
        Button { controller.launch(item) } label: {
            VStack(spacing: 7) {
                Image(nsImage: item.icon).resizable().interpolation(.high).frame(width: 39, height: 39)
                Text(item.name).font(.system(size: 10)).lineLimit(1).truncationMode(.tail)
            }.frame(maxWidth: .infinity).frame(height: 76)
        }
        .buttonStyle(TileButtonStyle())
        .help(item.name)
        .contextMenu { ApplicationContextMenu(item: item, applications: applications, preferences: preferences) { controller.launch(item) } }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            StartGlyph(size: 19)
            VStack(alignment: .leading, spacing: 2) {
                Text("Macbar").font(.system(size: 12, weight: .semibold))
                Text("Make yourself at home.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { controller.toggle(.settings) } label: { Image(systemName: "gearshape").font(.system(size: 16)).frame(width: 34, height: 34) }
                .buttonStyle(TileButtonStyle()).help("Macbar settings").accessibilityLabel("Macbar settings")
            Menu {
                Button("Quit Macbar") { NSApp.terminate(nil) }
            } label: { Image(systemName: "power").font(.system(size: 16)).frame(width: 28, height: 34) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Quit Macbar")
        }
        .padding(.horizontal, 32).padding(.vertical, 16)
        .background(.primary.opacity(0.035))
        .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.055)).frame(height: 1) }
    }
}
