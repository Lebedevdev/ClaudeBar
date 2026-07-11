#!/bin/bash
# Установка ClaudeBar: сборка из исходников → ~/Applications/ClaudeBar.app + автозапуск
set -e
cd "$(dirname "$0")"

APPDIR="$HOME/Applications/ClaudeBar.app"
PLIST="$HOME/Library/LaunchAgents/ru.lebedev.claudebar.plist"

echo "→ Компиляция ClaudeBar..."
swiftc -O -o /tmp/ClaudeBar ClaudeBar.swift

echo "→ Генерация иконки..."
swift makeicon.swift /tmp/ClaudeBar.iconset >/dev/null
iconutil -c icns /tmp/ClaudeBar.iconset -o /tmp/ClaudeBarIcon.icns

echo "→ Сборка .app..."
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp /tmp/ClaudeBar "$APPDIR/Contents/MacOS/ClaudeBar"
chmod +x "$APPDIR/Contents/MacOS/ClaudeBar"
cp /tmp/ClaudeBarIcon.icns "$APPDIR/Contents/Resources/AppIcon.icns"

cat > "$APPDIR/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeBar</string>
  <key>CFBundleDisplayName</key><string>ClaudeBar</string>
  <key>CFBundleIdentifier</key><string>ru.lebedev.claudebar</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>ClaudeBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PL

codesign --force --deep -s - "$APPDIR"

echo "→ Автозапуск (LaunchAgent)..."
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ru.lebedev.claudebar</string>
  <key>ProgramArguments</key>
  <array><string>$HOME/Applications/ClaudeBar.app/Contents/MacOS/ClaudeBar</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PL

launchctl bootout gui/$(id -u)/ru.lebedev.claudebar 2>/dev/null || true
pkill -f "ClaudeBar.app/Contents/MacOS/ClaudeBar" 2>/dev/null || true
sleep 1
launchctl bootstrap gui/$(id -u) "$PLIST"

echo "✅ ClaudeBar установлен — лимиты Claude в правом верхнем углу менюбара"
