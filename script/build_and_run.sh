#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP="${ZTYPE_APP_PATH:-}"
if [[ -z "$APP" ]]; then
    if [[ -d "/Applications/ztype.app" ]]; then
        APP="/Applications/ztype.app"
    elif [[ -d "$HOME/Applications/ztype.app" ]]; then
        APP="$HOME/Applications/ztype.app"
    else
        APP="$HOME/Library/Caches/ztype/Application/ztype.app"
    fi
fi
PROJECT_APP="$ROOT/dist/ztype.app"
if [[ "$MODE" == "--print-app-path" ]]; then
    printf '%s\n' "$APP"
    exit 0
fi
if [[ -e "$APP" ]]; then
    IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
    if [[ "$IDENTIFIER" != "app.ztype.mac" ]]; then
        printf 'Refusing to overwrite another application at %s\n' "$APP" >&2
        exit 1
    fi
fi
SIGNING_IDENTITY="${ZTYPE_SIGNING_IDENTITY:-}"
EXISTING_AUTHORITY=""
if [[ -e "$APP" ]]; then
    while IFS= read -r line; do
        if [[ "$line" == Authority=* ]]; then
            EXISTING_AUTHORITY="${line#Authority=}"
            break
        fi
    done < <(codesign --display --verbose=2 "$APP" 2>&1)
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    DEVELOPMENT_IDENTITIES=()
    while IFS= read -r line; do
        if [[ "$line" =~ ([0-9A-F]{40})\ \"([^\"]+)\" ]]; then
            HASH="${BASH_REMATCH[1]}"
            LABEL="${BASH_REMATCH[2]}"
            if [[ -n "$EXISTING_AUTHORITY" && "$LABEL" == "$EXISTING_AUTHORITY" ]]; then
                SIGNING_IDENTITY="$HASH"
                break
            fi
            if [[ "$LABEL" == "Apple Development: "* || "$LABEL" == "Developer ID Application: "* ]]; then
                DEVELOPMENT_IDENTITIES+=("$HASH")
            fi
        fi
    done < <(security find-identity -v -p codesigning)
    if [[ -z "$SIGNING_IDENTITY" && -n "$EXISTING_AUTHORITY" ]]; then
        printf 'Original signing identity unavailable; set ZTYPE_SIGNING_IDENTITY explicitly.\n' >&2
        exit 1
    fi
    if [[ -z "$SIGNING_IDENTITY" && ${#DEVELOPMENT_IDENTITIES[@]} -eq 1 ]]; then
        SIGNING_IDENTITY="${DEVELOPMENT_IDENTITIES[0]}"
    fi
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        SIGNING_IDENTITY="-"
        printf 'Warning: ad-hoc signing changes permission identity on rebuild. Set ZTYPE_SIGNING_IDENTITY for stable updates.\n' >&2
    fi
fi
if [[ "$MODE" != "--build-only" ]]; then
    pkill -x ztype >/dev/null 2>&1 || true
    for _ in {1..50}; do
        pgrep -x ztype >/dev/null || break
        sleep 0.1
    done
    # Also collect children left by an older development build or an app crash.
    pkill -f "^$APP/Contents/Resources/engine/llama-server" >/dev/null 2>&1 || true
    pkill -f "^$PROJECT_APP/Contents/Resources/engine/llama-server" >/dev/null 2>&1 || true
fi
BUILD_DIR="${ZTYPE_BUILD_DIR:-$HOME/Library/Caches/ztype/Build}"
swift build --scratch-path "$BUILD_DIR"
BIN="$(swift build --scratch-path "$BUILD_DIR" --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ztype" "$APP/Contents/MacOS/ztype"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/ThirdPartyNotices.md" "$APP/Contents/Resources/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$ROOT/Resources/AppIcon.png" "$APP/Contents/Resources/"
if [[ -d "$ROOT/Runtime/licenses" ]]; then
    cp -R "$ROOT/Runtime/licenses" "$APP/Contents/Resources/"
fi
if [[ -d "$ROOT/Runtime/engine" ]]; then
    mkdir -p "$APP/Contents/Resources/engine"
    cp -R "$ROOT/Runtime/engine/" "$APP/Contents/Resources/engine/"
fi
if [[ -f "$ROOT/Runtime/Qwen3-1.7B-Q8_0.gguf" && ! -f "$APP/Contents/Resources/Qwen3-1.7B-Q8_0.gguf" ]]; then
    cp -c "$ROOT/Runtime/Qwen3-1.7B-Q8_0.gguf" "$APP/Contents/Resources/" ||
        cp "$ROOT/Runtime/Qwen3-1.7B-Q8_0.gguf" "$APP/Contents/Resources/"
fi
xattr -cr "$APP"
codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp=none --identifier app.ztype.mac "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$ROOT/dist"
if [[ -L "$PROJECT_APP" ]]; then
    # Repair the development entry after the real bundle is moved or installed.
    ln -sfn "$APP" "$PROJECT_APP"
elif [[ ! -e "$PROJECT_APP" ]]; then
    ln -s "$APP" "$PROJECT_APP"
fi
touch "$APP"
touch -h "$PROJECT_APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP"
fi
case "$MODE" in
    --build-only) ;;
    run) open -n "$APP" ;;
    --verify) open -n "$APP"; sleep 2; pgrep -x ztype >/dev/null ;;
    --debug) lldb -- "$APP/Contents/MacOS/ztype" ;;
    --logs) open -n "$APP"; /usr/bin/log stream --info --predicate 'process == "ztype"' ;;
    --telemetry) open -n "$APP"; /usr/bin/log stream --info --predicate 'subsystem == "app.ztype.mac"' ;;
    *) printf 'Unknown mode: %s\n' "$MODE" >&2; exit 2 ;;
esac
