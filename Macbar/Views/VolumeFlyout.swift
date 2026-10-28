import SwiftUI

struct VolumeFlyout: View {
    @ObservedObject var audio: AudioStore
    let openSettings: () -> Void

    var body: some View {
        FlyoutSurface {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Sound").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(audio.output.canSetVolume ? "\(Int((audio.output.volume * 100).rounded()))%" : "—")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button { audio.toggleMute() } label: {
                        Image(systemName: audio.symbol).font(.system(size: 20)).frame(width: 36, height: 36)
                    }
                    .buttonStyle(TileButtonStyle(selected: audio.output.muted))
                    .disabled(!audio.output.canSetMute && !audio.output.canSetVolume)
                    .accessibilityLabel(audio.output.muted ? "Unmute" : "Mute")
                    .help(audio.output.muted ? "Unmute" : "Mute")

                    Slider(value: Binding(get: { audio.output.volume }, set: { audio.setVolume($0) }), in: 0...1)
                        .disabled(!audio.output.canSetVolume)
                        .accessibilityLabel("Output volume")
                        .accessibilityValue("\(Int((audio.output.volume * 100).rounded())) percent")
                }
                Label(audio.output.name, systemImage: "hifispeaker")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                if !audio.output.canSetVolume && audio.output.deviceID != 0 {
                    Text("Adjust volume on this output device.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let error = audio.error { Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 0)
                Divider().opacity(0.5)
                Button(action: openSettings) {
                    HStack { Text("Sound settings"); Spacer(); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { audio.refresh() }
    }
}
