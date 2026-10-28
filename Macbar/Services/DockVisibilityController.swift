import Foundation

/// The child owns the temporary Dock preferences and restores them when its input
/// closes, including if Macbar is force-quit. A lock serializes rapid restarts.
final class DockVisibilityController {
    private let domain: String
    private let recoveryDomain: String
    private let lockURL: URL
    private let restartPath: String
    private var input: FileHandle?
    private var helper: Process?

    init(domain: String = "com.apple.dock", recoveryDomain: String = "studio.macbar.dock-recovery",
         lockURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Macbar/dock.lock"),
         restartPath: String = "/usr/bin/killall") {
        self.domain = domain
        self.recoveryDomain = recoveryDomain
        self.lockURL = lockURL
        self.restartPath = restartPath
    }

    func recover() { launch(mode: "recover") }

    func setHidden(_ hidden: Bool) {
        if hidden {
            guard input == nil else { return }
            launch(mode: "hide")
        } else {
            try? input?.close()
            input = nil
            helper = nil
        }
    }

    private func launch(mode: String) {
        do {
            try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
            process.arguments = ["-k", lockURL.path, "/bin/sh", "-c", Self.script,
                                 "macbar-dock", domain, recoveryDomain, restartPath, mode]
            process.standardInput = pipe
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            if mode == "hide" {
                input = pipe.fileHandleForWriting
                helper = process
            } else {
                try? pipe.fileHandleForWriting.close()
            }
        } catch {
            NSLog("Macbar could not manage Dock visibility: %@", error.localizedDescription)
        }
    }

    // Only restore values still owned by Macbar, preserving changes made in System Settings.
    // The recovery journal is committed before the Dock is changed and survives a logout.
    private static let script = #"""
    dock="$1"; journal="$2"; restart="$3"; mode="$4"
    defaults=/usr/bin/defaults
    restart_dock() { "$restart" Dock >/dev/null 2>&1 || :; }
    restore() {
      [ "$("$defaults" read "$journal" ready 2>/dev/null)" = 1 ] || return
      changed=0
      current=$("$defaults" read "$dock" autohide 2>/dev/null || :)
      if [ "$current" = 1 ]; then
        if [ "$("$defaults" read "$journal" hasAutohide 2>/dev/null)" = 1 ]; then
          value=$("$defaults" read "$journal" autohide 2>/dev/null)
          case "$value" in 1) value=true ;; 0) value=false ;; esac
          "$defaults" write "$dock" autohide -bool "$value"
        else
          "$defaults" delete "$dock" autohide 2>/dev/null || :
        fi
        changed=1
      fi
      current=$("$defaults" read "$dock" autohide-delay 2>/dev/null || :)
      if [ -n "$current" ] && /usr/bin/awk -v n="$current" 'BEGIN { exit !(n == 1000) }'; then
        if [ "$("$defaults" read "$journal" hasDelay 2>/dev/null)" = 1 ]; then
          value=$("$defaults" read "$journal" delay 2>/dev/null)
          "$defaults" write "$dock" autohide-delay -float "$value"
        else
          "$defaults" delete "$dock" autohide-delay 2>/dev/null || :
        fi
        changed=1
      fi
      "$defaults" delete "$journal" >/dev/null 2>&1 || :
      [ "$changed" = 0 ] || restart_dock
    }
    restore
    [ "$mode" = hide ] || exit 0
    if value=$("$defaults" read "$dock" autohide 2>/dev/null); then
      "$defaults" write "$journal" hasAutohide -bool true
      case "$value" in 1) value=true ;; 0) value=false ;; esac
      "$defaults" write "$journal" autohide -bool "$value"
    else
      "$defaults" write "$journal" hasAutohide -bool false
    fi
    if value=$("$defaults" read "$dock" autohide-delay 2>/dev/null); then
      "$defaults" write "$journal" hasDelay -bool true
      "$defaults" write "$journal" delay -float "$value"
    else
      "$defaults" write "$journal" hasDelay -bool false
    fi
    "$defaults" write "$journal" ready -bool true
    "$defaults" write "$dock" autohide -bool true
    "$defaults" write "$dock" autohide-delay -float 1000
    restart_dock
    /bin/cat >/dev/null
    restore
    """#
}
