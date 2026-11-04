#!/usr/bin/env bash
# Build LGX packages for distribution via Basecamp Package Manager.
#
# Usage:
#   ./scripts/package-lgx.sh [output-dir]
#
# Output:
#   mymodule-core.lgx  — core C++ plugin (contains .so + bundled deps)
#   mymodule-ui.lgx    — QML UI plugin
#
# Prerequisites:
#   - Nix with flakes enabled
#   - Run from the template/ directory (or its parent)
#
# What is an LGX?
#   A tar.gz archive with a specific structure that Basecamp's Package Manager
#   can install. It contains a manifest.json at the root and platform-specific
#   variants under variants/<platform>/.
#
# IMPORTANT: If your module depends on libpcsclite (smartcard access),
#   uncomment the removal section below. Bundled libpcsclite breaks
#   communication with the system pcscd daemon.

set -euo pipefail

# Ensure nix is available
export PATH="/nix/var/nix/profiles/default/bin:$PATH"

OUTPUT_DIR="${1:-.}"
mkdir -p "$OUTPUT_DIR"

# Convert to absolute path (relative paths break inside subshells with cd)
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

echo "==> Building core module LGX with portable bundler..."
nix bundle --bundler github:logos-co/nix-bundle-lgx#portable .#lib

echo "==> Copying core LGX to output directory..."
cp -L mymodule-core-lgx-*/mymodule-core.lgx "$OUTPUT_DIR/mymodule-core.lgx"

# --- Uncomment if your module links against libpcsclite ---
# echo "==> Removing bundled libpcsclite for pcscd compatibility..."
# TEMP_DIR=$(mktemp -d)
# trap "rm -rf $TEMP_DIR" EXIT
# tar -xzf "$OUTPUT_DIR/mymodule-core.lgx" -C "$TEMP_DIR"
# find "$TEMP_DIR" -name "libpcsclite.so*" -delete
# (cd "$TEMP_DIR" && tar -czf "$OUTPUT_DIR/mymodule-core.lgx" *)
# --- End libpcsclite removal ---

echo "==> Building UI module LGX..."
nix bundle --bundler github:logos-co/nix-bundle-lgx#portable .#ui

echo "==> Copying UI LGX to output directory..."
cp -L mymodule-ui-lgx-*/mymodule-ui.lgx "$OUTPUT_DIR/mymodule-ui.lgx"

echo ""
echo "LGX packages ready in $OUTPUT_DIR:"
echo "  - mymodule-core.lgx"
echo "  - mymodule-ui.lgx"
echo ""
echo "To verify contents:"
echo "  tar -tzf $OUTPUT_DIR/mymodule-core.lgx"
echo "  tar -tzf $OUTPUT_DIR/mymodule-ui.lgx"
echo ""
echo "To install via Package Manager, copy the .lgx files to the"
echo "Basecamp Package Manager import directory, or use the UI."
