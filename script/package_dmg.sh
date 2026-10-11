#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    printf 'Packaging currently requires Apple Silicon macOS.\n' >&2
    exit 1
fi
python3 script/setup_engine.py --verify-only
BUILD_DIR="${ZTYPE_RELEASE_BUILD_DIR:-$HOME/Library/Caches/ztype/ReleaseBuild}"
swift build -c release --product ztype --scratch-path "$BUILD_DIR"
BIN="$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp/}ztype-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/ztype.app"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES/engine" "$RESOURCES/licenses"
cp "$BIN/ztype" "$APP/Contents/MacOS/ztype"
STRIP_TOOL="${ZTYPE_STRIP_TOOL:-}"
if [[ -z "$STRIP_TOOL" ]]; then
    for tool in "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin/strip" \
                /Library/Developer/CommandLineTools/usr/bin/strip; do
        if [[ -x "$tool" ]]; then STRIP_TOOL="$tool"; break; fi
    done
fi
if [[ -z "$STRIP_TOOL" || ! -x "$STRIP_TOOL" ]]; then
    printf 'No native strip tool available; install Xcode Command Line Tools.\n' >&2
    exit 1
fi
"$STRIP_TOOL" -S "$APP/Contents/MacOS/ztype"
python3 -c '
from pathlib import Path
import sys
if (str(Path.home()) + "/").encode() in Path(sys.argv[1]).read_bytes():
    raise SystemExit("Refusing to publish a binary containing local home-directory paths")
' "$APP/Contents/MacOS/ztype"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns Resources/AppIcon.png Resources/ThirdPartyNotices.md \
   Resources/runtime-assets.json LICENSE "$RESOURCES/"
cp Resources/licenses/llama.cpp-LICENSE Resources/licenses/Qwen-LICENSE "$RESOURCES/licenses/"
rsync -a --exclude='.DS_Store' --exclude='._*' Runtime/engine/ "$RESOURCES/engine/"
cp -c Runtime/Qwen3-1.7B-Q8_0.gguf "$RESOURCES/" ||
    cp Runtime/Qwen3-1.7B-Q8_0.gguf "$RESOURCES/"
xattr -cr "$APP"
IDENTITY="${ZTYPE_DISTRIBUTION_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
    printf 'Distribution build: ad-hoc signed, not notarized.\n'
    codesign --force --deep --sign - --timestamp=none --identifier app.ztype.mac "$APP"
else
    codesign --force --deep --sign "$IDENTITY" --options runtime \
        --identifier app.ztype.mac "$APP"
    printf 'Distribution signature applied. Notarization is still a separate step.\n'
fi
codesign --verify --deep --strict "$APP"
swift script/verify_app.swift "$APP"
ln -s /Applications "$STAGING/Applications"
cp Resources/Install.txt "$STAGING/Read Me.txt"
mkdir -p "$ROOT/dist"
DMG="${ZTYPE_DMG_OUTPUT:-$ROOT/dist/ztype-$VERSION-arm64.dmg}"
if [[ -e "$DMG" || -e "$DMG.sha256" ]]; then
    printf 'Refusing to overwrite an existing release artifact: %s\n' "$DMG" >&2
    exit 1
fi
hdiutil create -volname "ztype $VERSION" -srcfolder "$STAGING" \
    -format UDZO -imagekey zlib-level=6 "$DMG"
hdiutil verify "$DMG"
if [[ "$(stat -f '%z' "$DMG")" -ge 2147483648 ]]; then
    printf 'DMG exceeds the per-asset release limit; do not upload it.\n' >&2
    exit 1
fi
(
    cd "$(dirname "$DMG")"
    shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256"
)
printf 'Created %s\n' "$DMG"
printf 'Created %s.sha256\n' "$DMG"
