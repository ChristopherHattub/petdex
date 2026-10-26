#!/bin/bash
# Double-click (or launched from Petdex's Settings -> "Update my fork") to pull
# the fork, rebuild, and reinstall Petdex. Runs in Terminal so progress is visible.
cd "$(dirname "$0")/.." || exit 1
scripts/install-fork-macos.sh --yes
status=$?
echo
if [ "$status" -eq 0 ]; then echo "Petdex updated."; else echo "Update failed (exit $status). Scroll up for the error."; fi
read -r -p "Press Return to close this window. "
exit "$status"
