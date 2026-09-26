#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="launch"
for arg in "$@"; do
  case "$arg" in
    --debug) MODE="debug" ;;
    --logs) MODE="logs" ;;
    --telemetry) MODE="telemetry" ;;
    --verify) MODE="verify" ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

pkill -x RelayKey 2>/dev/null || true

swift build
BIN_PATH="$(swift build --show-bin-path)"
APP_DIR="$ROOT/dist/RelayKey.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
CONTENTS_DIR="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH/RelayKey" "$MACOS_DIR/RelayKey"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>RelayKey</string>
	<key>CFBundleIdentifier</key>
	<string>local.gabriel.relay-key</string>
	<key>CFBundleName</key>
	<string>RelayKey</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_DIR"
codesign --verify "$APP_DIR"

case "$MODE" in
  launch)
    /usr/bin/open -n "$APP_DIR"
    ;;
  debug)
    lldb "$MACOS_DIR/RelayKey"
    ;;
  logs)
    /usr/bin/open -n "$APP_DIR"
    sleep 1
    log stream --style compact --predicate 'process == "RelayKey"'
    ;;
  telemetry)
    /usr/bin/open -n "$APP_DIR"
    sleep 1
    log stream --predicate 'subsystem == "local.gabriel.relay-key"'
    ;;
  verify)
    /usr/bin/open -n "$APP_DIR"
    deadline=$((SECONDS + 10))
    launched=0
    while (( SECONDS < deadline )); do
      if pgrep -x RelayKey >/dev/null; then
        launched=1
        break
      fi
      sleep 0.2
    done
    if (( launched != 1 )); then
      echo "RelayKey did not launch within 10 seconds" >&2
      exit 1
    fi
    lsui="$(plutil -extract LSUIElement raw "$CONTENTS_DIR/Info.plist")"
    if [[ "$lsui" != "true" && "$lsui" != "1" ]]; then
      pkill -x RelayKey 2>/dev/null || true
      echo "LSUIElement is not true (got: $lsui)" >&2
      exit 1
    fi
    pkill -x RelayKey 2>/dev/null || true
    echo "verify ok: RelayKey launched, LSUIElement=$lsui"
    ;;
esac
