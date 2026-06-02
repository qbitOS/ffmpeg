import SwiftUI
import AppKit

/// Minimal host application for the Quick Look extensions.
/// 
/// Design goals for "tool extension" use:
/// - LSUIElement (set in project.yml / Info) → no Dock icon, does not appear in ⌘Tab, runs in background only when needed.
/// - No persistent background "spin". The process only runs when the user (or CLI) explicitly launches it (e.g. for registration after install/upgrade).
/// - All real work lives in the two QL extensions (self-contained, they load on-demand inside QuickLookUIService).
/// - Direct launch of bundled ffplay from the extension (no need to bounce through a running host app via URL scheme).
/// - Versioning + reconfig is driven by the external `mkvql` CLI tool.

@main
struct MKVQuickLookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // We still provide a tiny window so that if a user double-clicks the .app they see something useful
        // (status + "reconfigure" hint). Because of LSUIElement it won't steal focus or show in dock by default.
        WindowGroup("MKV QuickLook (tool)") {
            MinimalStatusView()
                .frame(width: 420, height: 260)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make absolutely sure we behave as a background agent even if Info.plist is stale.
        NSApp.setActivationPolicy(.accessory)

        // Optional: if launched with --register or from CLI, just touch registration and exit quickly.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--register-only") || args.contains("--headless") {
            // Perform any one-time registration side effects here if needed in future.
            // Then exit so we don't leave a process around.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApp.terminate(nil)
            }
        }

        // Normal case: user double-clicked the .app → the SwiftUI window above will show.
        // The window gives a tiny bit of UI for "this is the host for your mkv spacebar previews".
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // If the status window is closed, let the agent app quit. No lingering process.
        true
    }
}

/// Very small status view. The real configuration lives in the `mkvql` terminal tool.
struct MinimalStatusView: View {
    @State private var version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    @State private var build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "film.stack")
                    .font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MKV QuickLook Host")
                        .font(.title3.bold())
                    Text("v\(version) (\(build))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("This small agent app exists only to host the Quick Look Preview and Thumbnail extensions for .mkv files.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Managed from Terminal (recommended):")
                    .font(.headline)
                Text("  mkvql status")
                Text("  mkvql install")
                Text("  mkvql upgrade")
                Text("  mkvql reconfigure")
                Text("  mkvql uninstall")
            }
            .font(.system(.body, design: .monospaced))

            Text("The extensions are self-contained (your ffmpeg/ffplay are vendored at build time). No background daemon runs.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(20)
    }
}
