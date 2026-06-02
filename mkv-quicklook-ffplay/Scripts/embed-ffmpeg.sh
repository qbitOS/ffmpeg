#!/bin/zsh
#
# Embed-ffmpeg.sh
# Run this as a "Run Script" build phase in the main MKVQuickLook target.
# It vendors *your current* ffmpeg/ffplay/ffprobe (the ones with your codecs)
# into the app bundle so that the sandboxed Quick Look extensions can execute them reliably.
#
# Put it after "Copy Bundle Resources".
#
set -euo pipefail

# Allow override via env if you want a specific static build
FFMPEG_SRC="${FFMPEG_SRC:-$(command -v ffmpeg || echo /usr/local/bin/ffmpeg)}"
FFPLAY_SRC="${FFPLAY_SRC:-$(command -v ffplay || echo /usr/local/bin/ffplay)}"
FFPROBE_SRC="${FFPROBE_SRC:-$(dirname "$FFMPEG_SRC")/ffprobe}"

# Resolve destination. When run from Xcode build phase these vars are set.
# When invoked directly from the mkvql CLI we pass them or fall back to the just-built app.
if [[ -z "${BUILT_PRODUCTS_DIR:-}" || -z "${CONTENTS_FOLDER_PATH:-}" ]]; then
  # Try to find a recently built app next to us or in common locations
  CANDIDATE="${BUILT_PRODUCTS_DIR:-}"
  if [[ -z "$CANDIDATE" ]]; then
    CANDIDATE="$(pwd)/build/Release"
  fi
  if [[ -d "$CANDIDATE/MKVQuickLook.app" ]]; then
    DST_DIR="$CANDIDATE/MKVQuickLook.app/Contents/Resources/bin"
  else
    # Last resort: assume we are inside the source tree and a build product exists
    DST_DIR="${CANDIDATE}/MKVQuickLook.app/Contents/Resources/bin"
  fi
else
  DST_DIR="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/bin"
fi
mkdir -p "$DST_DIR"

echo "MKVQuickLook embed-ffmpeg: using"
echo "  ffmpeg:  $FFMPEG_SRC"
echo "  ffplay:  $FFPLAY_SRC"
echo "  ffprobe: $FFPROBE_SRC"
echo "  → $DST_DIR"

# Copy the binaries
install -m 0755 "$FFMPEG_SRC"  "$DST_DIR/ffmpeg"  || true
install -m 0755 "$FFPLAY_SRC"  "$DST_DIR/ffplay"  || true
install -m 0755 "$FFPROBE_SRC" "$DST_DIR/ffprobe" 2>/dev/null || true

# If they are dynamically linked, try to copy their dylibs and rewrite load commands.
# This makes the bundle more self-contained (good for extensions).
# Only attempt for files that look like our homebrew or /usr/local builds.

copy_and_fix_dylibs() {
    local bin="$1"
    local libdir="$DST_DIR/libs"
    mkdir -p "$libdir"

    # Use otool -L to find dependencies that live outside /usr/lib and /System
    otool -L "$bin" | awk 'NR>1 {print $1}' | while read -r dep; do
        case "$dep" in
            /usr/lib/*|/System/*|@rpath/*|@loader_path/*|@executable_path/*)
                # system or already relative — leave it
                ;;
            *)
                if [[ -f "$dep" ]]; then
                    local bn
                    bn=$(basename "$dep")
                    local dst="$libdir/$bn"
                    if [[ ! -f "$dst" ]]; then
                        cp -f "$dep" "$dst"
                        chmod +w "$dst"
                    fi
                    # Rewrite the binary to load from our libs dir
                    install_name_tool -change "$dep" "@loader_path/libs/$bn" "$bin" || true
                fi
                ;;
        esac
    done
}

# Fix the three tools (best effort)
for tool in "$DST_DIR/ffmpeg" "$DST_DIR/ffplay" "$DST_DIR/ffprobe"; do
    if [[ -x "$tool" ]]; then
        copy_and_fix_dylibs "$tool" || true
        # Also give the tool an rpath to its own libs dir
        install_name_tool -add_rpath "@loader_path/libs" "$tool" 2>/dev/null || true
        install_name_tool -add_rpath "@loader_path" "$tool" 2>/dev/null || true
    fi
done

echo "MKVQuickLook: ffmpeg embedding complete."
# You can also force the paths into UserDefaults here at build, but runtime choose is nicer.
