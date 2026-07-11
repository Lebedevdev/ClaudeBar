#!/bin/bash
# Пересборка ClaudeBar: ./build.sh
set -e
cd "$(dirname "$0")"
APPDIR="$HOME/Applications/ClaudeBar.app"
swiftc -O -o /tmp/ClaudeBar ClaudeBar.swift
launchctl bootout gui/$(id -u)/ru.lebedev.claudebar 2>/dev/null || true
pkill -f "ClaudeBar.app/Contents/MacOS/ClaudeBar" 2>/dev/null || true
sleep 1
cp /tmp/ClaudeBar "$APPDIR/Contents/MacOS/ClaudeBar"
codesign --force --deep -s - "$APPDIR"
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/ru.lebedev.claudebar.plist"
echo "✅ Пересобрано и перезапущено"
