import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var access: AccessibilityStatus
    @State private var modifierRefused = false

    var body: some View {
        Form {
            Section("Trigger") {
                HStack {
                    ForEach(Modifiers.ordered.indices, id: \.self) { i in
                        let item = Modifiers.ordered[i]
                        Toggle(item.symbol, isOn: Binding(
                            get: { settings.modifiers.contains(item.flag) },
                            set: { modifierRefused = !settings.setModifier(item.flag, $0) }
                        ))
                        .toggleStyle(.button)
                    }
                    Spacer()
                    Text("\(settings.modifiers.symbols) + key").foregroundStyle(.secondary)
                }
                if modifierRefused {
                    Text("Keep at least one of ⌃ ⌥ ⌘.").font(.caption).foregroundStyle(.red)
                }
            }

            Section("Apps") {
                if settings.bindings.isEmpty {
                    Text("No apps yet. Add one below.").foregroundStyle(.secondary)
                }
                ForEach(settings.bindings, id: \.key) { binding in
                    BindingRow(
                        binding: binding,
                        failed: settings.failedKeys.contains(binding.key),
                        change: { pickApp(for: binding.key) },
                        remove: { settings.removeBinding(binding.key) }
                    )
                }
                Menu("Add…") {
                    ForEach(freeKeys, id: \.self) { key in
                        Button("\(settings.modifiers.symbols)\(key.rawValue)") { pickApp(for: key) }
                    }
                }
                .disabled(freeKeys.isEmpty)
                .fixedSize()
            }

            Section("Layout") {
                Stepper("Gap: \(Int(settings.gap)) px", value: $settings.gap, in: SettingsStore.gapRange, step: 2)
                Toggle("Hide other windows", isOn: Binding(
                    get: { settings.hideOthers },
                    set: { settings.setHideOthers($0) }
                ))
                LabeledContent("Never hide") {
                    Button("Add…") { pickKeptApp() }
                }
                .disabled(!settings.hideOthers)
                ForEach(settings.keptApps, id: \.bundleID) { app in
                    KeptAppRow(app: app) { settings.removeKeptApp(bundleID: app.bundleID) }
                }
                .disabled(!settings.hideOthers)
                Text("\(settings.modifiers.symbols) + ← → ↑ ↓ moves the dividers while 2+ windows are tiled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(settings.modifiers.symbols) + 2…5 gives the right window 1/2…1/5 of the width; the next digit sets the bottom window's height")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Drag an edge between tiled windows to resize them together")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Press a key again while holding \(settings.modifiers.symbols) to tile another window of its app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Tap \(settings.modifiers.symbols) alone to let the tile go: its windows stay put and stop snapping back")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(settings.modifiers.symbols) + [ / ] steps back / forward through recent chords")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Accessibility") {
                    if access.trusted {
                        Text("Granted").foregroundStyle(.secondary)
                    } else {
                        Button("Grant…") { access.openSettings() }
                    }
                }
                LabeledContent("All permissions") {
                    Button("Open…") { PermissionsWindow.shared.show() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }

    private var freeKeys: [TriggerKey] {
        TriggerKey.allCases.filter { settings.bindings.binding(for: $0) == nil }
    }

    /// An app picked in an open panel, or nil (a beep if it has no bundle ID).
    private func chooseApp(message: String) -> (url: URL, bundleID: String, name: String)? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose"
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            NSSound.beep()
            return nil
        }
        return (url, bundleID, url.deletingPathExtension().lastPathComponent)
    }

    private func pickApp(for key: TriggerKey) {
        guard let app = chooseApp(message: "App for \(settings.modifiers.symbols)\(key.rawValue)") else { return }
        settings.setBinding(AppBinding(key: key, bundleID: app.bundleID, appName: app.name, appPath: app.url.path))
    }

    private func pickKeptApp() {
        guard let app = chooseApp(message: "App whose windows are never hidden") else { return }
        settings.addKeptApp(KeptApp(bundleID: app.bundleID, appName: app.name, appPath: app.url.path))
    }
}

private struct BindingRow: View {
    let binding: AppBinding
    let failed: Bool
    let change: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack {
            Text(binding.key.rawValue)
                .font(.system(.body, design: .monospaced))
                .frame(width: 20)
            Image(nsImage: NSWorkspace.shared.icon(forFile: binding.appPath))
                .resizable()
                .frame(width: 20, height: 20)
            Text(binding.appName)
            if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("This shortcut is taken by another app.")
            }
            Spacer()
            Button("Change…", action: change)
            Button(action: remove) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove")
        }
    }
}

private struct KeptAppRow: View {
    let app: KeptApp
    let remove: () -> Void

    var body: some View {
        HStack {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.appPath))
                .resizable()
                .frame(width: 20, height: 20)
            Text(app.appName)
            Spacer()
            Button(action: remove) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove")
        }
    }
}
