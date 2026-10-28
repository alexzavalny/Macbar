import SwiftUI

struct SettingsFlyout: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var windowManagement: WindowManagementStore

    var body: some View {
        FlyoutSurface {
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    StartGlyph(size: 29).frame(width: 46, height: 46).background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Macbar").font(.system(size: 19, weight: .semibold))
                        Text("A different kind of home base.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("0.1").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Appearance").font(.system(size: 12, weight: .medium))
                    Picker("Appearance", selection: $preferences.appearance) {
                        ForEach(BarAppearance.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Alignment").font(.system(size: 12, weight: .medium))
                    Picker("Alignment", selection: $preferences.alignment) {
                        ForEach(TaskbarAlignment.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                VStack(spacing: 14) {
                    Toggle("Compact taskbar", isOn: $preferences.compact)
                    if preferences.taskbarMode == .icons {
                        Toggle("Show app labels", isOn: $preferences.showAppLabels)
                    }
                }.toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                VStack(alignment: .leading, spacing: 10) {
                    Text("Taskbar mode").font(.system(size: 12, weight: .medium))
                    Picker("Taskbar mode", selection: $preferences.taskbarMode) {
                        ForEach(TaskbarMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    if preferences.taskbarMode == .icons {
                        Toggle("Separate apps with multiple windows", isOn: $preferences.separateMultipleWindows)
                            .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                        if preferences.separateMultipleWindows {
                            Text("Show a titled tile for each window when an app has two or more windows, including minimized windows.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if preferences.taskbarMode == .windows {
                        Text("One tile per window, with its title beside the icon. Includes minimized windows.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if preferences.usesWindowTiles && !windowManagement.hasAccessibilityAccess {
                        Text("Allow Accessibility access to show separate windows. Until then, tiles show app names.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Allow window access…") { windowManagement.requestAccessibilityAccess() }
                            .buttonStyle(.bordered).font(.system(size: 11))
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Keep windows above taskbar", isOn: $preferences.keepWindowsAboveTaskbar)
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    if preferences.keepWindowsAboveTaskbar {
                        if windowManagement.hasAccessibilityAccess {
                            Text("Maximized windows leave room for Macbar.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        } else {
                            Text("Allow Macbar in Accessibility settings to adjust maximized windows.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Allow window management…") { windowManagement.requestAccessibilityAccess() }
                                .buttonStyle(.bordered).font(.system(size: 11))
                        }
                    }
                }
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 9) {
                    Label("Settle in", systemImage: "dock.rectangle").font(.system(size: 12, weight: .semibold))
                    Toggle("Hide Dock while Macbar is running", isOn: $preferences.hideDockWhileRunning)
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    Text("Your previous Dock settings return when Macbar quits.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Desktop & Dock Settings ↗") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
                    }.buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 11, weight: .medium))
                }
                Spacer(minLength: 0)
                HStack {
                    Text("Drag tiles to reorder. Right-click for more.").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(25).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.scrollIndicators(.hidden)
        }
    }
}
