#!/usr/bin/env bash
# Build this fork, package it as an ad-hoc signed Petdex.app, and make it the
# only Petdex on this Mac: the old app is quit and moved to the Trash, the
# mounted disk image it may be running from is ejected, a Homebrew cask is
# uninstalled, and petdex:// is re-pointed at the new bundle.
#
# Ad-hoc signing is enough for the machine that builds the app; it is NOT a
# distributable build (see scripts/sign-macos.sh for that). Your pets and
# settings live in ~/.petdex and are left untouched.
#
# Usage: scripts/install-fork-macos.sh [--yes]
#   --yes  skip the confirmation prompt
set -euo pipefail

[ "$(uname -s)" = "Darwin" ] || { echo "macOS only" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Self-update: pull the fork's main first, and restart this script if it
# changed, so one command is always enough. The clone may still be sitting on
# a feature branch whose PR was merged (that branch never moves again), so
# switch to main when the working tree is clean; building a stale branch and
# reporting success is the failure this guards against.
if [ -z "${PETDEX_UPDATED:-}" ]; then
  BEFORE="$(git -C "$REPO" rev-parse HEAD)"
  BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
  if [ "$BRANCH" != "main" ]; then
    if git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet; then
      git -C "$REPO" fetch --quiet origin main && git -C "$REPO" checkout --quiet main \
        && echo "Switched from $BRANCH to main." \
        || echo "warning: could not switch to main; building $BRANCH" >&2
    else
      echo "warning: $BRANCH has uncommitted changes, so staying on it. Commit or stash them to update from main." >&2
    fi
  fi
  if [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" = "main" ]; then
    git -C "$REPO" pull --ff-only --quiet origin main || echo "warning: could not fast-forward main; building what is checked out" >&2
  else
    git -C "$REPO" pull --ff-only --quiet || echo "warning: could not pull; building what is checked out" >&2
  fi
  if [ "$BEFORE" != "$(git -C "$REPO" rev-parse HEAD)" ]; then
    echo "Pulled new changes; restarting."
    PETDEX_UPDATED=1 exec "$REPO/scripts/install-fork-macos.sh" "$@"
  fi
fi
echo "Building $(git -C "$REPO" rev-parse --abbrev-ref HEAD) at $(git -C "$REPO" log -1 --format='%h %s')"
PKG="$REPO/packages/petdex-desktop-native"
SRC="${PETDEX_SRC:-$HOME/src}"
SDK_REF=c0b10d027efa490fc99a3bc7f1cf88b015999d45
DEST=/Applications/Petdex.app
TRASH="$HOME/.Trash"
STAMP="$(date +%Y%m%d-%H%M%S)"

if [ "${1:-}" != "--yes" ]; then
  cat <<MSG
This will:
  - build $REPO (branch $(git -C "$REPO" rev-parse --abbrev-ref HEAD))
  - quit Petdex and move any old Petdex.app to the Trash
  - eject the Petdex disk image if it is mounted
  - uninstall the Homebrew cask 'petdex' if present
  - install the fork to $DEST
Your pets and settings in ~/.petdex are kept.
MSG
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || exit 1
fi

# --- toolchain: Zig 0.16.0 and the pinned, patched Native SDK ---------------
if [ ! -x "$SRC/toolchains/zig-venv/bin/python" ]; then
  python3 -m venv "$SRC/toolchains/zig-venv"
  "$SRC/toolchains/zig-venv/bin/pip" install -q ziglang==0.16.0
fi
ZIG_DIR="$("$SRC/toolchains/zig-venv/bin/python" -c 'import ziglang,os;print(os.path.dirname(ziglang.__file__))')"
export PATH="$ZIG_DIR:$PATH"

if [ ! -d "$SRC/native-sdk/.git" ]; then
  git clone --depth 1 -b feat/floating-window-0.5.3 https://github.com/Railly/native.git "$SRC/native-sdk"
  git -C "$SRC/native-sdk" fetch --depth 1 origin "$SDK_REF"
  git -C "$SRC/native-sdk" checkout --detach "$SDK_REF"
fi
export NATIVE_SDK_PATH="$SRC/native-sdk"
"$REPO/scripts/patch-native-sdk.sh"
[ -x "$SRC/native-sdk/zig-out/bin/native" ] || (cd "$SRC/native-sdk" && zig build cli)
NATIVE="$SRC/native-sdk/zig-out/bin/native"

# --- build and package -------------------------------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
(cd "$PKG" && "$NATIVE" build -Dcpu=baseline -Dtrace=off)
(cd "$PKG" && "$NATIVE" package --target macos \
  --binary zig-out/bin/petdex-desktop-native \
  --output "$STAGE/Petdex.app" --signing adhoc)
codesign --verify --deep --strict "$STAGE/Petdex.app"

# --- retire every other Petdex ----------------------------------------------
osascript -e 'tell application "Petdex" to quit' 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -f petdex-desktop-native >/dev/null || break; sleep 1; done
pkill -f petdex-desktop-native 2>/dev/null || true

for volume in /Volumes/Petdex*; do
  [ -d "$volume" ] && hdiutil detach "$volume" -quiet 2>/dev/null || true
done

for old in "$DEST" "$HOME/Applications/Petdex.app"; do
  if [ -e "$old" ]; then
    mv "$old" "$TRASH/Petdex-old-$STAMP.app"
    echo "moved $old to the Trash"
  fi
done

BREW="$(command -v brew || ls /opt/homebrew/bin/brew /usr/local/bin/brew 2>/dev/null | head -1 || true)"
if [ -n "$BREW" ] && "$BREW" list --cask petdex >/dev/null 2>&1; then
  "$BREW" uninstall --cask petdex || echo "brew could not remove the petdex cask; run: brew uninstall --cask petdex"
fi

# --- install ------------------------------------------------------------------
ditto "$STAGE/Petdex.app" "$DEST" || { echo "Could not write $DEST. Re-run with: sudo ditto '$STAGE/Petdex.app' '$DEST'" >&2; trap - EXIT; exit 1; }
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f -R -trusted "$DEST" >/dev/null 2>&1 || true

# Double-clickable updater on the Desktop: pull, rebuild, reinstall.
LAUNCHER="$HOME/Desktop/Update Petdex.command"
printf '#!/bin/bash\nexec "%s/scripts/install-fork-macos.sh" --yes\n' "$REPO" > "$LAUNCHER"
chmod +x "$LAUNCHER"

echo
echo "Installed $DEST. Launching it now."
open "$DEST"
cat <<MSG

Last step: Petdex menu -> Settings -> turn on 'Launch at login'.
To update later: double-click 'Update Petdex' on your Desktop (it pulls, rebuilds and reinstalls).
Find leftovers with: mdfind "kMDItemCFBundleIdentifier == 'dev.petdex.desktop-native'"
MSG
