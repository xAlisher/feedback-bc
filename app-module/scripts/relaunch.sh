#!/usr/bin/env bash
# Kill ALL Logos processes and relaunch the AppImage.
#
# Why kill everything? Logos runs multiple processes (logos_host, LogosApp, logos_core).
# If you only kill one, the others hold file locks on your old .so.
# Your new build won't load and you'll waste 30 minutes debugging.
#
# Why -f flag? AppImage wraps executables via ld-linux, so process names
# become long paths. Plain pkill doesn't match. -f matches the full command line.
set -euo pipefail

APPIMAGE="${LOGOS_APPIMAGE:-$HOME/logos-app/logos-app.AppImage}"

echo "==> Killing all Logos processes..."
pkill -9 -f "logos_host" 2>/dev/null || true
pkill -9 -f "LogosApp" 2>/dev/null || true
pkill -9 -f "logos_core" 2>/dev/null || true
pkill -9 -f "logos-app.AppImage" 2>/dev/null || true
sleep 2

# Verify they're all dead
REMAINING=$(ps aux | grep -i logos | grep -v grep | grep -v "relaunch.sh" || true)
if [ -n "$REMAINING" ]; then
    echo "WARNING: Some Logos processes still running:"
    echo "$REMAINING"
    echo ""
    echo "Kill them manually with: kill -9 <pid>"
    exit 1
fi

echo "==> All Logos processes killed."

# Launch
if [ ! -f "$APPIMAGE" ]; then
    echo "ERROR: AppImage not found at $APPIMAGE"
    echo "Set LOGOS_APPIMAGE env var to the correct path."
    exit 1
fi

echo "==> Launching $APPIMAGE..."
"$APPIMAGE" &
echo "==> Launched. Check the Basecamp sidebar for your module."
