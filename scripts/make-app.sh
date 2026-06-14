#!/bin/sh
# ケイラボAIラジオ .app バンドルを作る（仕様 s20）。アドホック署名・このMac専用。
#
# 使い方:
#   sh scripts/make-app.sh              # config を秘密(*.local.yaml)込みでコピー（すぐ動く・このMac専用）
#   sh scripts/make-app.sh --no-secrets # *.local.yaml を除外（共有用。キーは各自で入れる）
#
# 出力: dist/ケイラボAIラジオ/（.app + config を同梱した1フォルダ）。
#       フォルダごと配置・削除でインストール/完全アンインストール。
set -eu

APP_NAME="ケイラボAIラジオ"
EXEC="AIRadioApp"
BUNDLE_ID="io.github.tokumeishatyo.airadio"
VERSION="1.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist/$APP_NAME"
APP="$DIST/$APP_NAME.app"

NO_SECRETS="0"
[ "${1:-}" = "--no-secrets" ] && NO_SECRETS="1"

echo "==> swift build -c release"
( cd "$ROOT" && swift build -c release )
BIN="$ROOT/.build/release/$EXEC"
[ -f "$BIN" ] || { echo "実行ファイルが見つかりません: $BIN" >&2; exit 1; }

echo "==> バンドル組み立て: $APP"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$EXEC"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHumanReadableCopyright</key><string>本アプリは VOICEVOX を使用しています。</string>
</dict>
</plist>
PLIST

echo "==> config をコピー"
mkdir -p "$DIST/config"
cp -R "$ROOT/config/." "$DIST/config/"
if [ "$NO_SECRETS" = "1" ]; then
    rm -f "$DIST/config/"*.local.yaml
    echo "    （--no-secrets: *.local.yaml を除外しました）"
fi

echo "==> アドホック署名"
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP" >/dev/null 2>&1 && echo "    署名 OK" || echo "    署名検証に失敗（続行可）"

echo ""
echo "✅ 完成: $APP"
echo "   フォルダ: $DIST"
echo ""
echo "起動方法:"
echo "  初回は Finder で「$APP_NAME.app」を右クリック → 開く（Gatekeeper を1回許可）。以降はダブルクリック。"
echo "前提:"
echo "  VOICEVOX を起動 / Spotify を起動 + Premium。Spotify 未ログインならメニューの「Spotify にログイン」から。"
if [ "$NO_SECRETS" = "0" ]; then
    echo ""
    echo "⚠️  $DIST は API キー（config/*.local.yaml）を含みます。このフォルダは共有しないでください。"
fi
