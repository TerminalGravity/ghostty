#!/bin/bash
# Replace /Applications/Ghostty.app with a fork build.
#
# Quitting Ghostty closes every tab, so run this detached from Ghostty:
#   nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' \
#     bash ~/Projects/ghostty/agent/install-macos.sh >/dev/null 2>&1 &
# Log: ~/Library/Logs/ghostty-swap.log. Roll back with the same script:
#   install-macos.sh ~/Applications/Ghostty-previous.app
set -euo pipefail

SRC=${1:-$HOME/Projects/ghostty/zig-out-release/Ghostty.app}
DEST=/Applications/Ghostty.app
BACKUP=$HOME/Applications/Ghostty-previous.app
CONFIG=$HOME/.config/ghostty/config
exec >>"$HOME/Library/Logs/ghostty-swap.log" 2>&1

echo "== $(date '+%F %T') install $SRC"
[ -d "$SRC" ] || { echo "missing $SRC"; exit 1; }
STAGE=$(mktemp -d)/Ghostty.app
ditto "$SRC" "$STAGE"

# Sparkle would replace the fork with the official build.
if ! grep -q '^auto-update *=' "$CONFIG" 2>/dev/null; then
  printf '\n# Fork build: keep Sparkle from replacing it.\nauto-update = off\n' >> "$CONFIG"
fi

osascript -e 'tell application id "com.mitchellh.ghostty" to quit' || true
for _ in $(seq 1 60); do
  pgrep -f "$DEST/Contents/MacOS/ghostty" >/dev/null || break
  sleep 1
done
if pgrep -f "$DEST/Contents/MacOS/ghostty" >/dev/null; then
  echo "Ghostty did not quit; nothing changed"
  exit 1
fi

mkdir -p "$HOME/Applications"
if [ "$SRC" != "$BACKUP" ]; then
  rm -rf "$BACKUP"
  mv "$DEST" "$BACKUP"
else
  rm -rf "$DEST"
fi
mv "$STAGE" "$DEST"
/usr/bin/xattr -cr "$DEST"
open -a "$DEST"
echo "done: $("$DEST/Contents/MacOS/ghostty" +version | head -1)"
