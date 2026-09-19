#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "=== Starting SpotDL-NG Uninstallation ==="

INSTALL_DIR="$HOME/.local/share/spotdl-ng"
DESKTOP_FILE="$HOME/.local/share/applications/spotdl-ng.desktop"

# 1. Remove application directory
if [ -d "$INSTALL_DIR" ]; then
    echo "Removing application directory at $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
else
    echo "Application directory not found."
fi

# 2. Remove desktop shortcut
if [ -f "$DESKTOP_FILE" ]; then
    echo "Removing desktop shortcut at $DESKTOP_FILE..."
    rm -f "$DESKTOP_FILE"
else
    echo "Desktop shortcut not found."
fi

# 3. Update desktop database if available
if command -v update-desktop-database &> /dev/null; then
    echo "Updating desktop database..."
    update-desktop-database "$HOME/.local/share/applications"
fi

# 4. Uninstall spotdl Python package
echo "Uninstalling spotdl..."
if command -v pip &> /dev/null; then
    pip uninstall -y spotdl || true
elif command -v pip3 &> /dev/null; then
    pip3 uninstall -y spotdl || true
else
    echo "Pip not found, skipping python package removal."
fi

echo "=== Uninstallation Completed Successfully! ==="
