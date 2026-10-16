#!/bin/bash
# Build QGuard.app from main.swift (no Xcode project needed).
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$HOME/Applications/QGuard.app}"

echo "==> compiling"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -framework Cocoa -framework ApplicationServices \
  -o "$APP/Contents/MacOS/QGuard" "$SRC_DIR/main.swift"

echo "==> icon"
swift "$SRC_DIR/makeicon.swift" "$SRC_DIR/icon.png" >/dev/null
ICONSET="$SRC_DIR/QGuard.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s        "$SRC_DIR/icon.png" --out "$ICONSET/icon_${s}x${s}.png"       >/dev/null
  sips -z $((s*2)) $((s*2)) "$SRC_DIR/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/QGuard.icns"
rm -rf "$ICONSET"

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>QGuard</string>
  <key>CFBundleDisplayName</key><string>QGuard</string>
  <key>CFBundleIdentifier</key><string>com.tom.qguard</string>
  <key>CFBundleExecutable</key><string>QGuard</string>
  <key>CFBundleIconFile</key><string>QGuard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

echo "==> signing"
# Ad-hoc by default: TCC validates ad-hoc signatures fine. A self-signed cert
# only survives rebuilds if its root is trusted SYSTEM-wide; a login-keychain
# trust makes codesign happy but TCC still refuses the grant. Opt in with
# QGUARD_IDENTITY="Some Identity" only if that cert is in the System keychain.
if [ -n "${QGUARD_IDENTITY:-}" ] && security find-identity -v -p codesigning | grep -q "$QGUARD_IDENTITY"; then
  codesign --force --sign "$QGUARD_IDENTITY" --identifier com.tom.qguard "$APP"
else
  codesign --force --sign - --identifier com.tom.qguard "$APP"
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# Ad-hoc ties the grant to the binary hash, so a rebuild silently invalidates
# Accessibility while the toggle still LOOKS on. Clear it so the next launch
# asks for a fresh grant instead of failing silently.
if [ "${QGUARD_RESET_TCC:-1}" = "1" ]; then
  tccutil reset Accessibility com.tom.qguard >/dev/null 2>&1 \
    && echo "    note: Accessibility reset — re-enable QGuard after launch."
fi

echo "==> built: $APP"
