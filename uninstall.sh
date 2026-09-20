#!/bin/bash

set -e

echo "=== Removing SpotDL-NG ==="

INSTALL_DIR="$HOME/.local/share/spotdl-ng"
DESKTOP_FILE="$HOME/.local/share/applications/spotdl-ng.desktop"
LAUNCHER="$HOME/.local/bin/spotdl-ng"

# 1. Remove application directory and virtual environment
if [ -d "$INSTALL_DIR" ]; then
    echo "Removing application files from $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
else
    echo "Application directory not found."
fi

# 2. Remove desktop shortcut
if [ -f "$DESKTOP_FILE" ]; then
    echo "Removing desktop shortcut..."
    rm -f "$DESKTOP_FILE"
    if command -v update-desktop-database &> /dev/null; then
        update-desktop-database "$HOME/.local/share/applications"
    fi
else
    echo "Desktop shortcut not found."
fi

# 3. Remove global terminal command
if [ -f "$LAUNCHER" ]; then
    echo "Removing terminal executable from $LAUNCHER..."
    rm -f "$LAUNCHER"
else
    echo "Terminal command not found."
fi

echo "=== Uninstall Completed Successfully! ==="
