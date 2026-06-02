import Cocoa
import QuickLookUI
import AVKit
import SwiftUI
import UniformTypeIdentifiers

// This file belongs *only* to the MKVQuickLookQLPreview target.
// In Xcode: also add MKVMetadata.swift + FFMPEG.swift to this target's Compile Sources (they are designed to be multi-target).

final class PreviewViewController: NSViewController, QLPreviewingController {

    private var currentURL: URL?
    private var hostingView: NSHostingView<AnyView>?

    // We keep a temp remux around for the lifetime of this preview instance.
    private var remuxTempURL: URL?

    override func loadView() {
        // The QL system will size us. Start with a reasonable container.
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        self.view.wantsLayer = true
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        currentURL = url

        // Parse metadata (fast, pure Swift)
        let md: MKVMetadata
        do {
            md = try parseMKVMetadata(at: url)
        } catch {
            md = MKVMetadata(filename: url.lastPathComponent,
                             fileSize: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)) ?? 0,
                             duration: nil, title: nil, tracks: [])
        }

        // Try to produce a playable asset for native controls inside QL.
        // Strategy: use ffmpeg (if reachable) to remux a (clip of) the file to mp4.
        // This gives us the beautiful built-in video player UI (scrubber, volume, fullscreen, PiP, etc).
        var playerView: AVPlayerView?
        var playableAsset: AVAsset?

        let remuxLimit = FFMPEG.remuxLimitSeconds()   // from user config (mkvql reconfigure); nil = full file
        if let remuxed = FFMPEG.remuxToMP4(source: url, durationLimit: remuxLimit) {
            remuxTempURL = remuxed
            let asset = AVAsset(url: remuxed)
            if asset.isPlayable {
                playableAsset = asset
                let player = AVPlayer(url: remuxed)
                let pv = AVPlayerView()
                pv.player = player
                pv.controlsStyle = .inline
                pv.showsFullScreenToggleButton = true
                pv.showsSharingServiceButton = true
                playerView = pv
            } else {
                // Not playable after remux → we'll show the "use ffplay" path
                try? FileManager.default.removeItem(at: remuxed)
                remuxTempURL = nil
            }
        }

        // Build the SwiftUI content
        let content = MKVPreviewContent(
            url: url,
            metadata: md,
            playerView: playerView,
            onPlayWithFFPlay: { [weak self] in
                self?.triggerFFPlay(for: url)
            },
            onOpenInIINA: { [weak self] in self?.openInExternal("IINA", for: url) },
            onOpenInVLC: { [weak self] in self?.openInExternal("VLC", for: url) }
        )

        let anyView = AnyView(content)
        let host = NSHostingView(rootView: anyView)
        host.translatesAutoresizingMaskIntoConstraints = false

        // Clear previous
        hostingView?.removeFromSuperview()
        view.subviews.forEach { $0.removeFromSuperview() }

        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingView = host

        // If we have a playable asset, auto-play (muted first frame is common for QL video previews)
        if let pv = playerView, let p = pv.player {
            p.isMuted = true
            p.play()
            // Unmute after a short delay so user gets instant visual without audio surprise
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                p.isMuted = false
            }
        }

        handler(nil)
    }

    private func triggerFFPlay(for url: URL) {
        // Directly launch the bundled (or system) ffplay from inside the sandboxed extension.
        // Because we vendor the binaries into the host .app's Resources/bin at build time (via the embed script),
        // the extension can exec them reliably. We also respect the user config written by the `mkvql` CLI.
        FFMPEG.launchFFPlayConfigured(on: url)
    }

    private func openInExternal(_ appName: String, for url: URL) {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appName == "IINA" ? "com.colliderli.iina" : "org.videolan.vlc") {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: .init())
        } else {
            // Fallback to open with any registered or ffplay
            if appName == "IINA" || appName == "VLC" {
                NSWorkspace.shared.open(url)
            } else {
                FFMPEG.launchFFPlay(on: url)
            }
        }
    }

    deinit {
        // Best effort cleanup of any remux temp we created for this preview
        if let tmp = remuxTempURL {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

// MARK: - SwiftUI preview UI

struct MKVPreviewContent: View {
    let url: URL
    let metadata: MKVMetadata
    let playerView: AVPlayerView?   // if non-nil we embed via NSViewRepresentable
    let onPlayWithFFPlay: () -> Void
    let onOpenInIINA: () -> Void
    let onOpenInVLC: () -> Void

    @State private var showCopied = false

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Image(systemName: "film")
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(metadata.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let d = metadata.duration {
                    Text(String(format: "  %.0fs", d))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)

            // Main area: either the real AVPlayer or a rich placeholder + metadata
            ZStack {
                if let pv = playerView {
                    PlayerContainer(playerView: pv)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Attractive placeholder + big action buttons
                    VStack(spacing: 18) {
                        Spacer()
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.black.opacity(0.6))
                                .frame(width: 220, height: 140)
                            Image(systemName: "play.rectangle.on.rectangle")
                                .font(.system(size: 56))
                                .foregroundStyle(.white.opacity(0.85))
                        }

                        VStack(spacing: 4) {
                            Text("Native playback unavailable for this codec/container combo")
                                .font(.callout)
                                .multilineTextAlignment(.center)
                            Text("Your build of ffmpeg can decode it — ffplay will use all the codecs you compiled in.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 380)
                        }

                        Button(action: onPlayWithFFPlay) {
                            Label("Play with ffplay (your full codecs)", systemImage: "play.fill")
                                .font(.headline)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)

                        HStack(spacing: 12) {
                            Button("Open in IINA", action: onOpenInIINA)
                            Button("Open in VLC", action: onOpenInVLC)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.path, forType: .string)
                                withAnimation { showCopied = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                    showCopied = false
                                }
                            } label: {
                                Label(showCopied ? "Path copied" : "Copy path", systemImage: showCopied ? "checkmark" : "doc.on.doc")
                            }
                        }
                        .buttonStyle(.borderless)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }

            // Bottom metadata strip (always visible, useful even when playing)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(metadata.tracks) { track in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.type.rawValue.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(track.codecID)
                                .font(.system(.caption, design: .monospaced))
                            if let lang = track.language {
                                Text(lang)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    if metadata.tracks.isEmpty {
                        Text("No track info (or parser limited on this file)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(height: 52)
            .background(.regularMaterial)
        }
    }
}

private struct PlayerContainer: NSViewRepresentable {
    let playerView: AVPlayerView

    func makeNSView(context: Context) -> NSView {
        // The AVPlayerView is already configured by caller.
        // We just wrap it so SwiftUI can host it.
        let container = NSView()
        playerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: container.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
