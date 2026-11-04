#!/usr/bin/env bash
# Build and install the module to LogosBasecamp.
# Run from the template/ directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Building..."
cmake --build "$PROJECT_DIR/build"

echo "==> Installing..."
cmake --install "$PROJECT_DIR/build" --prefix ~/.local

# Fix execute permissions (CMake install sometimes strips them)
MODULE_SO="$HOME/.local/share/Logos/LogosBasecamp/modules/mymodule/mymodule_plugin.so"
if [ -f "$MODULE_SO" ]; then
    chmod +x "$MODULE_SO"
    echo "==> Set execute permission on $MODULE_SO"
fi

echo ""
echo "Installed. Run ./scripts/relaunch.sh to test."
