#!/bin/zsh
# Sestaví Kukatko.app (a s --instaluj ji rovnou dá do /Applications a spustí).
set -e
cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=$ROOT/dist
APP=$OUT/Kukatko.app

swift build -c release
BIN=$(swift build -c release --show-bin-path)/Kukatko

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Kukatko"
VERZE=$(cat balicek/VERZE)
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" -e "s/__VERZE__/$VERZE/" balicek/Info.plist > "$APP/Contents/Info.plist"

# Ikona (jen když chybí nebo se změnil zdroj)
ICNS=$OUT/AppIcon.icns
if [[ ! -f $ICNS || balicek/ikona.swift -nt $ICNS ]]; then
  TMP=$(mktemp -d)
  swift balicek/ikona.swift "$TMP/1024.png"
  mkdir "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o "$ICNS"
  rm -rf "$TMP"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Stálý podpis drží povolení Zpřístupnění i přes nová sestavení; bez certifikátu ad-hoc.
IDENT="Kukatko Code Signing"
if security find-identity -p codesigning | grep -q "$IDENT"; then
  codesign --force --sign "$IDENT" --identifier cz.filipskluzacek.kukatko "$APP"
else
  echo "Pozor: certifikát „$IDENT“ chybí, podepisuji ad-hoc (Zpřístupnění se bude po každém sestavení ztrácet)."
  codesign --force --sign - --identifier cz.filipskluzacek.kukatko "$APP"
fi
rm -f "$OUT/Kukatko.zip"
ditto -c -k --keepParent "$APP" "$OUT/Kukatko.zip"
echo "Hotovo: $APP (+ Kukatko.zip ke sdílení)"

if [[ $1 == --instaluj ]]; then
  osascript -e 'tell application "Kukátko" to quit' 2>/dev/null || true
  pkill -x Kukatko 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Kukatko.app
  cp -R "$APP" /Applications/
  /System/Library/CoreServices/pbs -update 2>/dev/null || true
  open /Applications/Kukatko.app
  echo "Nainstalováno do /Applications a spuštěno."
fi
