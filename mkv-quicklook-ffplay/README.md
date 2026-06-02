# mkvql — MKV QuickLook Tool Extension (terminal-driven)

A **pure terminal managed** macOS Quick Look add-on that makes `.mkv` (and `.webm`) files first-class citizens in Finder's spacebar preview.

- Press **Space** on any `.mkv` → rich metadata + **playable video**.
- Uses **your** already-built `ffmpeg`/`ffplay` (all the codecs you compiled in).
- **No persistent background app or "spin"**. The host is a tiny LSUIElement agent that only runs when you (or the CLI) explicitly launch it for registration. The real work happens inside the on-demand Quick Look extension processes.
- Fully managed from the terminal: `install`, `upgrade`, `reconfigure`, `uninstall`, `status`.
- Built-in versioning + reconfigurable settings (no rebuild needed to change ffplay flags or preview clip length).

## Architecture (why it doesn't need a GUI app running)

- A minimal host `.app` (`MKVQuickLook.app`) whose only job is to contain + register two modern Quick Look extensions (Preview + Thumbnail).
- The host is marked `LSUIElement` (agent) → never appears in Dock or ⌘Tab by default.
- The extensions are **self-contained**:
  - They vendor (copy + rewrite rpaths of) your `ffmpeg`/`ffplay`/`ffprobe` at build/install time into `MKVQuickLook.app/Contents/Resources/bin/`.
  - They can therefore `exec` the tools even though they run sandboxed by QuickLook.
  - "Play" button inside the preview launches the vendored ffplay **directly** (no bouncing to a host process via URL schemes).
- Result: after `mkvql install` you can quit everything. Finder spacebar just works. No daemons, no login items, no menu bar apps.

Configuration lives in `~/Library/Application Support/MKVQuickLook/config.plist` (written by the CLI). Extensions read it on every preview.

## Install & daily use (all from terminal)

```bash
cd ~/dev/mkv-quicklook-ffplay          # or wherever you keep the checkout

# One-time (or after git pull / changes)
./bin/mkvql install

# Or with the global binary after first install:
mkvql install --install-cli            # also puts `mkvql` into /usr/local/bin

# Later, when you update your ffmpeg or want new features
mkvql upgrade

# Change behavior without rebuilding
mkvql reconfigure \
  --ffplay-args "-autoexit -volume 85 -window_title MKV" \
  --remux-seconds 45                    # only remux first 45s for native player (saves disk on huge files)

# See everything
mkvql status
mkvql doctor

# Remove cleanly
mkvql uninstall --remove-cli
```

After `install` or `upgrade`:
1. The CLI runs `xcodegen` (if needed) + `xcodebuild` to produce a fresh `MKVQuickLook.app`.
2. It vendors your current `$(command -v ffmpeg)` etc. into the bundle (your exact codecs + any custom patches).
3. It atomically replaces `~/Applications/MKVQuickLook.app`.
4. It calls `lsregister` + `qlmanage -r` so Finder sees the new extensions immediately.
5. It briefly launches the agent (headless) for any first-run side effects, then it exits.

Press **Space** on a `.mkv`. Done.

## Reconfiguration (no rebuild, instant)

All of these are live for the next preview you open:

- `ffplayExtraArgs` — any flags you love (your dither scripts, hwaccel, subtitle filters, etc.).
- `remuxPreviewSeconds` — 0 = full-file fast copy (best quality/compatibility for supported codecs). N = only the first N seconds as a temp mp4 (much less disk for 50 GB remuxes).
- `autoVendorOnUpgrade` — whether `upgrade` should always pull in the ffmpeg that's currently on your `$PATH`.

The CLI writes `~/Library/Application Support/MKVQuickLook/config.plist`. The extensions and host read it with zero other processes.

## Versioning & updates

- The `mkvql` CLI itself has a version (`mkvql version`).
- Every built host `.app` gets `CFBundleShortVersionString` + `CFBundleVersion` stamped (from the CLI version + a build timestamp, overridable by env `MKVQL_VERSION` / `MKVQL_BUILD`).
- `mkvql upgrade` does a `git pull --ff-only` (if the tree is a git checkout), rebuilds, re-vendors, and replaces the installed app.
- Config has its own `version` field for future migrations.

This makes the whole thing behave like a proper upgradable "lib/tool".

## What gets built / shipped

When you run `install`/`upgrade`:

- `MKVQuickLook.xcodeproj` (generated from `project.yml` by xcodegen — fully reproducible from terminal).
- Three targets:
  - `MKVQuickLook` — the tiny LSUIElement host app.
  - `MKVQuickLookQLPreview` — the spacebar preview (metadata + either native AVPlayer after remux or big "Play with ffplay" button).
  - `MKVQuickLookQLThumbnail` — Finder icon thumbnails (real frame via ffmpeg or nice drawn placeholder with duration + track badges).
- The embed script runs as a build phase (and can be re-run by the CLI) and produces a self-contained `Resources/bin/{ffmpeg,ffplay,ffprobe}` + fixed dylibs.

All of this is driven by the single `mkvql` binary / wrapper. No need to open Xcode.

## Requirements on the target Mac

- macOS 11+
- Xcode + command line tools (for `xcodebuild` during `install`/`upgrade`)
- `xcodegen` (the install step can `brew install xcodegen` for you, or you pre-install)
- Your `ffmpeg`/`ffplay` somewhere in PATH (or pass `FFMPEG_SRC=...` env)

The resulting installed `.app` has **no runtime dependency** on the source checkout or even on having Xcode present.

## Advanced / power user

- Point the CLI at a different source tree: `mkvql --source-root /path/to/checkout status`
- Force a specific ffmpeg for this build: `FFMPEG_SRC=/opt/homebrew/bin/ffmpeg ./bin/mkvql install`
- Static ffmpeg: build one with `--enable-static --disable-shared`, put it on PATH, and the embed will copy the single binary (even better for sandboxing).
- Multiple machines: `git clone` the dir (or tar it up after a build), run `mkvql install` on each. The vendored binaries travel with the .app.

## Troubleshooting

- Previews not appearing for .mkv after install:
  - `mkvql status`
  - `qlmanage -r ; qlmanage -r cache`
  - Check Console for `com.qbit.MKVQuickLook` or `QuickLook` while pressing Space on a file.
  - `mdls -name kMDItemContentType yourfile.mkv` should say `org.matroska.mkv`
- "ffmpeg not found" inside preview: run `mkvql upgrade` (it re-vendors). Or `mkvql doctor`.
- ffplay launches but you want different defaults: `mkvql reconfigure --ffplay-args '...'`
- Conflicts with QLVideo / Oil3 Mkv-Quicklook: `mkvql uninstall`, disable the other in System Settings → General → Login Items / Extensions, then reinstall.
- Want the host app to show a window on double-click? It does (tiny status). Close the window → agent quits (no lingering process).

## Files you care about as a user of the tool

```
bin/mkvql                 ← run this (or the globally installed one)
Package.swift + Sources/mkvql/   ← the CLI source (ArgumentParser)
project.yml               ← declarative description of the whole Xcode project (xcodegen)
Scripts/embed-ffmpeg.sh   ← the vendoring magic (called from build + CLI)
Sources/Shared/           ← parser + ffmpeg runner + config (used by extensions + host)
Sources/PreviewExtension/ + ThumbnailExtension/  ← the actual QL bits
MKVQuickLook.xcodeproj    ← generated, reproducible
```

## Development of mkvql itself

```bash
# edit code
./bin/mkvql install --force     # or just the swift build + manual steps if iterating on extensions
```

Because everything is driven from `project.yml` + shell steps, you never have to open the Xcode GUI to produce a working, versioned, upgradable release.

Enjoy spacebar previews with every codec you ever compiled into ffmpeg, managed like a proper command-line tool.

---

(Internal note: this README + the `mkvql` CLI + generated project replace the old "open Xcode and click a lot" flow. The previous heavy GUI app with menu bar and manual registration is gone; everything is now a first-class upgradable terminal extension.)
