#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -quiet -project Macbar.xcodeproj -scheme Macbar -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build build

built_app="$PWD/build/Build/Products/Debug/Macbar.app"
installed_app="/Applications/Macbar.app"
requirement='anchor apple generic and identifier "studio.macbar.app" and certificate leaf[subject.OU] = "7RAJ8692JX"'

# Never install an ad-hoc build: privacy grants need a stable signing identity.
codesign --verify --deep --strict -R="$requirement" "$built_app"

# Quit only Macbar copies from this checkout or the stable installation path.
for executable in "$built_app/Contents/MacOS/Macbar" "$installed_app/Contents/MacOS/Macbar"; do
  for macbar_pid in $(pgrep -x Macbar || true); do
    running_executable="$(ps -p "$macbar_pid" -o comm=)"
    if [[ "$running_executable" == "$executable" ]]; then
      kill -TERM "$macbar_pid"
      for attempt in {1..50}; do
        kill -0 "$macbar_pid" 2>/dev/null || break
        sleep 0.1
      done
      if kill -0 "$macbar_pid" 2>/dev/null; then
        print -u2 "Macbar did not quit. Quit it before installing the new build."
        exit 1
      fi
    fi
  done
done

# Keep the permission target at the same path across command-line rebuilds.
rsync -a --delete "$built_app/" "$installed_app/"
codesign --verify --deep --strict -R="$requirement" "$installed_app"
open "$installed_app"
