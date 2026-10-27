#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
scripts/build-app.sh

target="$HOME/Applications/Amp Workbench.app"
mkdir -p "$HOME/Applications"

# Keep the installed bundle separate from the build directory so it remains
# available after a clean build. User data lives in Application Support.
if [[ -d "$target" ]]; then
  if pgrep -f "$target/Contents/MacOS/AmpWorkbench" >/dev/null; then
    osascript -e 'tell application id "org.example.amp-workbench" to quit' >/dev/null 2>&1 || true
    for attempt in {1..20}; do
      pgrep -f "$target/Contents/MacOS/AmpWorkbench" >/dev/null || break
      sleep 0.25
    done
    if pgrep -f "$target/Contents/MacOS/AmpWorkbench" >/dev/null; then
      echo "Quit Amp Workbench before updating it." >&2
      exit 1
    fi
  fi
  rm -rf "$target"
fi
ditto "dist/Amp Workbench.app" "$target"
codesign --verify --deep "$target"
echo "Installed $target"
