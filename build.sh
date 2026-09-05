#!/bin/zsh
set -e
cd "${0:A:h}"
APP="Hitsudan.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=(Sources/TabletHID.swift Sources/PenPointer.swift Sources/CanvasView.swift
         Sources/BoardBridge.swift Sources/Widgets.swift Sources/InputMap.swift
         Sources/PageStore.swift Sources/DollarRecognizer.swift
         Sources/Version.swift Sources/Updater.swift
         Sources/MainWindow.swift Sources/main.swift)

# 自動更新はバージョンを比べて動くので、Info.plist の値が実物と合っていないと
# 意味がない。CI はタグを HITSUDAN_VERSION で渡す。手元では直近のタグを拾い、
# タグが無ければ 0.0.0（＝リリースがあれば必ず「更新あり」側になる）。
VERSION="${HITSUDAN_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || true)}"
VERSION="${VERSION#v}"
VERSION="${VERSION:-0.0.0}"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "error: バージョン '$VERSION' が数字とドットだけになっていません" >&2
  exit 1
fi

# Without an explicit -target the SDK's own version becomes the minimum, so the
# binary silently demands the OS it was built on while Info.plist claims 13.0.
# Build both slices and stitch them, so this runs on Intel Macs too.
DEPLOY=13.0
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "${ARCH}-apple-macosx${DEPLOY}" \
    "${SOURCES[@]}" \
    -framework AppKit -framework IOKit \
    -o "/tmp/hitsudan-$ARCH"
done
lipo -create "/tmp/hitsudan-arm64" "/tmp/hitsudan-x86_64" \
  -output "$APP/Contents/MacOS/Hitsudan"

# icon: SVG is the source, rasterised through NSImage
swiftc -O -target "arm64-apple-macosx${DEPLOY}" Tools/makeicon.swift -o /tmp/hitsudan-makeicon
/tmp/hitsudan-makeicon Resources/icon.svg /tmp/Hitsudan.iconset >/dev/null
iconutil -c icns /tmp/Hitsudan.iconset -o "$APP/Contents/Resources/Hitsudan.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>筆談ボード</string>
  <key>CFBundleDisplayName</key><string>筆談ボード</string>
  <key>CFBundleExecutable</key><string>Hitsudan</string>
  <key>CFBundleIdentifier</key><string>local.hitsudan.board</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleIconFile</key><string>Hitsudan</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string></string>
</dict>
</plist>
PLIST

# A stable identity, not ad-hoc: an ad-hoc signature's cdhash changes on every
# build, which silently revokes the Input Monitoring grant each time.
#
# HITSUDAN_SIGN_IDENTITY overrides it — that is how CI signs with a Developer ID.
# A Developer ID signature also needs the hardened runtime and a timestamp, or
# notarisation refuses the submission.
IDENTITY="${HITSUDAN_SIGN_IDENTITY:-Hitsudan Local Signing}"
SIGN_FLAGS=()
REQUIRE_IDENTITY=0
if [[ -n "${HITSUDAN_SIGN_IDENTITY:-}" ]]; then
  # 明示的に指定された以上、見つからないのは設定ミス。ここで黙って
  # アドホックに落ちると、CI が署名済みのつもりで配ってしまう。
  REQUIRE_IDENTITY=1
  SIGN_FLAGS=(--options runtime --timestamp)
fi

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP"
  echo "signed: $IDENTITY"
elif (( REQUIRE_IDENTITY )); then
  echo "error: HITSUDAN_SIGN_IDENTITY に指定された '$IDENTITY' に一致する証明書が" >&2
  echo "       キーチェーンにありません。security find-identity -v -p codesigning に" >&2
  echo "       出る文字列をそのまま指定してください。" >&2
  exit 1
else
  echo "warning: '$IDENTITY' が見つかりません。アドホック署名にフォールバックします"
  echo "         （再ビルドのたびに入力監視の許可が外れます。README の『署名鍵の再作成』参照）"
  codesign --force --sign - "$APP" 2>/dev/null || true
fi

# stdio MCP server: lets a running Claude session pull the board directly
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "${ARCH}-apple-macosx${DEPLOY}" Sources/mcpmain.swift \
    -framework CoreGraphics -framework ImageIO \
    -o "/tmp/hitsudan-mcp-$ARCH"
done
lipo -create "/tmp/hitsudan-mcp-arm64" "/tmp/hitsudan-mcp-x86_64" -output hitsudan-mcp

echo "built: $PWD/$APP (バージョン $VERSION)"
echo "built: $PWD/hitsudan-mcp"
