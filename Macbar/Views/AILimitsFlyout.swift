import SwiftUI

struct AILimitsFlyout: View {
    @ObservedObject var limits: AILimitsStore

    var body: some View {
        FlyoutSurface {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("AI Limits").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button { limits.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                        .buttonStyle(TileButtonStyle())
                        .disabled(AIProvider.allCases.contains { limits.state(for: $0).isRefreshing })
                        .help("Refresh usage limits").accessibilityLabel("Refresh usage limits")
                }
                Text("Remaining usage in your current subscription windows.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(AIProvider.allCases) { provider in providerCard(provider) }
                    }
                }.scrollIndicators(.hidden)
                Text("Uses the Codex and Claude Code accounts signed in on this Mac. Credentials and usage aren’t saved by Macbar.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { limits.refresh() }
    }

    private func providerCard(_ provider: AIProvider) -> some View {
        let state = limits.state(for: provider)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                AIProviderIcon(provider: provider, size: 24)
                Spacer()
                if state.isRefreshing { ProgressView().controlSize(.small) }
                Button("Open usage ↗") { NSWorkspace.shared.open(provider.usageURL) }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Color.accentColor)
            }
            if let snapshot = state.snapshot {
                if state.error != nil { Text("Last known limits").font(.system(size: 10)).foregroundStyle(.secondary) }
                ForEach(snapshot.windows) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(window.title).font(.system(size: 11))
                            Spacer()
                            Text("\(Int(window.remainingPercent.rounded(.down)))% remaining")
                                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        }
                        ProgressView(value: window.remainingPercent, total: 100)
                            .tint(window.remainingPercent <= 10 ? .red : .accentColor)
                            .accessibilityLabel("\(provider.title), \(window.title), remaining usage")
                        if let reset = window.resetsAt {
                            HStack(spacing: 3) {
                                Text(reset > Date() ? "Resets in" : "Reset was")
                                Text(reset, style: .relative)
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                                .help(reset.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
                Text("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            } else if state.isRefreshing {
                Text("Reading limits…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error = state.error {
                Text(error.localizedDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .keychainAccess = error {
                    Button("Allow Claude access…") { limits.refresh(only: .claude, allowKeychainPrompt: true) }
                        .buttonStyle(.bordered).controlSize(.small).disabled(state.isRefreshing)
                }
            }
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AILimitsTrayLabel: View {
    @ObservedObject var limits: AILimitsStore

    var body: some View {
        VStack(spacing: 3) {
            ForEach(AIProvider.allCases) { provider in
                HStack(spacing: 2) {
                    AIProviderIcon(provider: provider, size: 16)
                    Text(summary(provider)).monospacedDigit().frame(width: 30, alignment: .leading)
                }.font(.system(size: 10, weight: .medium))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(provider.title), \(summary(provider)) remaining")
                    .help("\(provider.title) · \(summary(provider)) remaining")
            }
        }.padding(.horizontal, 4).frame(width: 56, height: 40)
    }

    private func summary(_ provider: AIProvider) -> String {
        let state = limits.state(for: provider)
        guard state.error == nil, let snapshot = state.snapshot, let remaining = snapshot.remainingPercent,
              snapshot.summaryWindows.allSatisfy({ $0.resetsAt.map { $0 > Date() } ?? true }) else { return "—" }
        return "\(Int(remaining.rounded(.down)))%"
    }
}

private struct AIProviderIcon: View {
    let provider: AIProvider
    let size: CGFloat

    var body: some View {
        Image("AIProvider-\(provider.rawValue)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(provider == .claude ? Color(red: 0.85, green: 0.55, blue: 0.40) : Color.primary)
            .accessibilityLabel(provider.title)
            .help(provider.title)
    }
}
