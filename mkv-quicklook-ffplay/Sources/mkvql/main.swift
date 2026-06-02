import Foundation
import ArgumentParser

// MARK: - mkvql
// Terminal-first manager for the MKV QuickLook tool extension.
// 
// Usage examples:
//   mkvql install
//   mkvql upgrade
//   mkvql reconfigure --ffplay-args "-autoexit -volume 90" --remux-seconds 45
//   mkvql status
//   mkvql uninstall
//
// This tool builds (via xcodebuild + the generated project.yml) a minimal LSUIElement host .app
// that contains the two self-contained Quick Look extensions. The extensions use vendored
// copies of your ffmpeg/ffplay so they work with zero other processes running in the background.
// No URL scheme hacks, no persistent agents, no spin-up on every Finder action.

@main
struct MKVQL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mkvql",
        abstract: "Manage the MKV QuickLook Finder spacebar preview tool (ffmpeg-powered).",
        version: "1.0.0",
        subcommands: [Install.self, Upgrade.self, Uninstall.self, Status.self, Reconfigure.self, Doctor.self, VersionCmd.self],
        defaultSubcommand: Status.self
    )

    // Common options
    struct Options: ParsableArguments {
        @Flag(name: .long, help: "Force actions even if versions match or files exist.")
        var force: Bool = false

        @Option(name: .long, help: "Path to the MKVQuickLook source checkout (contains MKVQuickLook.xcodeproj and Sources).")
        var sourceRoot: String?

        @Option(name: .long, help: "Destination directory for the host .app (default: ~/Applications).")
        var installDir: String?
    }
}

extension MKVQL {
    static func resolveSourceRoot(_ override: String?) -> URL {
        if let o = override, !o.isEmpty {
            return URL(fileURLWithPath: o).standardizedFileURL
        }
        // Try env
        if let env = ProcessInfo.processInfo.environment["MKVQL_SOURCE_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env).standardizedFileURL
        }
        // Walk up from this executable
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<8 {
            let proj = dir.appendingPathComponent("MKVQuickLook.xcodeproj")
            if FileManager.default.fileExists(atPath: proj.path) {
                return dir
            }
            // Also look for Package.swift as marker
            let pkg = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: pkg.path) && dir.lastPathComponent != "mkvql" {
                // May be the root
                let proj2 = dir.appendingPathComponent("MKVQuickLook.xcodeproj")
                if FileManager.default.fileExists(atPath: proj2.path) {
                    return dir
                }
            }
            dir = dir.deletingLastPathComponent()
        }
        // Fallback: current directory
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
    }

    static func defaultInstallDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Applications", isDirectory: true)
    }

    static func installedAppURL(in dir: URL) -> URL {
        dir.appendingPathComponent("MKVQuickLook.app", isDirectory: true)
    }

    static func runShell(_ command: String, cwd: URL? = nil, env: [String: String]? = nil) throws -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        if let cwd { task.currentDirectoryURL = cwd }
        if let env { task.environment = env }

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (task.terminationStatus, output)
    }

    static func stampVersion(into appURL: URL, version: String, build: String) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: infoURL.path) else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
        task.arguments = ["-c", "Set :CFBundleShortVersionString \(version)", infoURL.path]
        try? task.run()
        task.waitUntilExit()

        let task2 = Process()
        task2.executableURL = URL(fileURLWithPath: "/usr/libexec/PlistBuddy")
        task2.arguments = ["-c", "Set :CFBundleVersion \(build)", infoURL.path]
        try? task2.run()
        task2.waitUntilExit()
    }

    static func registerApp(_ appURL: URL) throws {
        let (code, out) = try runShell("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f \"\(appURL.path)\"")
        if code != 0 {
            fputs("lsregister warning: \(out)\n", stderr)
        }
        // Also clear QL caches so new extensions are picked up immediately
        _ = try? runShell("/usr/bin/qlmanage -r 2>/dev/null; /usr/bin/qlmanage -r cache 2>/dev/null || true")
    }

    static func currentToolVersion() -> String {
        // This is the version of the mkvql CLI itself
        return MKVQL.configuration.version
    }

    static func appVersion(from appURL: URL) -> (String, String)? {
        let info = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: info) as? [String: Any] else { return nil }
        let v = dict["CFBundleShortVersionString"] as? String ?? "unknown"
        let b = dict["CFBundleVersion"] as? String ?? "0"
        return (v, b)
    }
}

// MARK: - Subcommands

extension MKVQL {
    struct VersionCmd: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "version", abstract: "Show mkvql and (if installed) host app versions.")

        @OptionGroup var options: MKVQL.Options

        func run() throws {
            print("mkvql (CLI): \(MKVQL.currentToolVersion())")

            let root = MKVQL.resolveSourceRoot(options.sourceRoot)
            let installDir = options.installDir.map { URL(fileURLWithPath: $0) } ?? MKVQL.defaultInstallDir()
            let app = MKVQL.installedAppURL(in: installDir)

            if let (v, b) = MKVQL.appVersion(from: app) {
                print("Installed host app: \(v) (\(b)) at \(app.path)")
            } else {
                print("No installed host app found at \(app.path)")
            }
            print("Source root: \(root.path)")
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show current installation and configuration status.")

        @OptionGroup var options: MKVQL.Options

        func run() throws {
            let root = MKVQL.resolveSourceRoot(options.sourceRoot)
            let installDir = options.installDir.map { URL(fileURLWithPath: $0) } ?? MKVQL.defaultInstallDir()
            let app = MKVQL.installedAppURL(in: installDir)

            print("Source checkout: \(root.path)")
            print("Project: \(root.appendingPathComponent("MKVQuickLook.xcodeproj").path)")
            print("Target install dir: \(installDir.path)")
            print("Installed app: \(app.path) — exists: \(FileManager.default.fileExists(atPath: app.path))")

            if let (v, b) = MKVQL.appVersion(from: app) {
                print("  Version: \(v) build \(b)")
            }

            let cfg = FFMPEGConfigBridge.load()
            print("\nCurrent reconfigurable settings (from \(MKVQLConfig.configURL.path)):")
            print("  ffplay extra args: \(cfg.ffplayExtraArgs.joined(separator: " "))")
            print("  remux preview seconds: \(cfg.remuxPreviewSeconds) (0 = full file)")
            print("  auto-vendor on upgrade: \(cfg.autoVendorOnUpgrade)")

            // Check for ffmpeg presence for vendoring
            let ff = ProcessInfo.processInfo.environment["FFMPEG_SRC"] ?? (getenv("FFMPEG").flatMap { String(cString: $0) } ?? "")
            _ = ff // only used for diagnostics in doctor
            let which = (try? MKVQL.runShell("command -v ffmpeg || echo 'not in PATH'").1.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "?"
            print("\nSystem ffmpeg candidate: \(which)")
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Build the host .app (with vendored ffmpeg) and install it so Finder spacebar works for .mkv.")

        @OptionGroup var options: MKVQL.Options

        @Flag(help: "Also install the mkvql binary to /usr/local/bin (or ~/bin).")
        var installCli: Bool = false

        func run() throws {
            let root = MKVQL.resolveSourceRoot(options.sourceRoot)
            let installDir = options.installDir.map { URL(fileURLWithPath: $0) } ?? MKVQL.defaultInstallDir()
            try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

            print("Building from source root: \(root.path)")

            // Ensure generated project exists
            let proj = root.appendingPathComponent("MKVQuickLook.xcodeproj")
            if !FileManager.default.fileExists(atPath: proj.path) {
                print("Generating Xcode project with xcodegen...")
                let (genCode, genOut) = try MKVQL.runShell("xcodegen generate --spec project.yml --project .", cwd: root)
                if genCode != 0 { throw ValidationError("xcodegen failed: \(genOut)") }
            }

            let buildDir = root.appendingPathComponent(".build-mkvql")
            try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

            let scheme = "MKVQuickLook"
            let config = "Release"

            print("Running xcodebuild (this may take a minute the first time)...")
            let buildCmd = """
            xcodebuild -project "\(proj.path)" \
              -scheme "\(scheme)" \
              -configuration "\(config)" \
              -derivedDataPath "\(buildDir.path)" \
              ONLY_ACTIVE_ARCH=NO \
              CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
              build
            """
            let (buildCode, buildOut) = try MKVQL.runShell(buildCmd, cwd: root)
            if buildCode != 0 {
                fputs(buildOut, stderr)
                throw ValidationError("xcodebuild failed (exit \(buildCode)). See output above.")
            }

            // Locate the built .app
            let possible = [
                buildDir.appendingPathComponent("Build/Products/Release/MKVQuickLook.app"),
                root.appendingPathComponent("build/Release/MKVQuickLook.app")
            ]
            guard let builtApp = possible.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw ValidationError("Could not find built MKVQuickLook.app after xcodebuild.")
            }
            print("Built app at: \(builtApp.path)")

            // Run the embed script manually here (in case the build phase didn't fully vendor or we want to force current ffmpeg)
            let cfg = FFMPEGConfigBridge.load()
            if cfg.autoVendorOnUpgrade {
                print("Vendoring current ffmpeg/ffplay into the app bundle...")
                let embedScript = root.appendingPathComponent("Scripts/embed-ffmpeg.sh")
                if FileManager.default.isExecutableFile(atPath: embedScript.path) {
                    let env = ProcessInfo.processInfo.environment.merging([
                        "BUILT_PRODUCTS_DIR": builtApp.deletingLastPathComponent().path,
                        "CONTENTS_FOLDER_PATH": "MKVQuickLook.app/Contents"
                    ]) { _, new in new }
                    _ = try? MKVQL.runShell("FFMPEG_SRC=\"$(command -v ffmpeg)\" FFPLAY_SRC=\"$(command -v ffplay)\" \"\(embedScript.path)\"", cwd: root, env: env)
                }
            }

            // Stamp version
            let toolVer = MKVQL.currentToolVersion()
            let buildNum = String(Int(Date().timeIntervalSince1970))
            try MKVQL.stampVersion(into: builtApp, version: toolVer, build: buildNum)

            // Install (atomic replace)
            let destApp = MKVQL.installedAppURL(in: installDir)
            if FileManager.default.fileExists(atPath: destApp.path) {
                print("Removing previous installation at \(destApp.path)")
                try FileManager.default.removeItem(at: destApp)
            }
            try FileManager.default.copyItem(at: builtApp, to: destApp)
            print("Installed to \(destApp.path)")

            // Register with LaunchServices + refresh QL
            print("Registering with the system (lsregister + qlmanage)...")
            try MKVQL.registerApp(destApp)

            // Optionally launch headless once so any first-run registration code runs
            print("Launching agent app once (headless) to complete registration...")
            _ = try? MKVQL.runShell("open -g \"\(destApp.path)\" --args --headless")

            print("\n✅ Success. Press Space on any .mkv in Finder.")
            print("   Manage later with: mkvql upgrade | reconfigure | status | uninstall")

            if installCli {
                try installSelfCLI(to: root)
            }
        }

        private func installSelfCLI(to root: URL) throws {
            print("Building mkvql release binary...")
            let (code, out) = try MKVQL.runShell("swift build -c release --package-path .", cwd: root)
            if code != 0 { fputs(out, stderr); throw ValidationError("swift build failed") }

            let releaseBin = root.appendingPathComponent(".build/release/mkvql")
            guard FileManager.default.fileExists(atPath: releaseBin.path) else {
                throw ValidationError("Built binary not found at \(releaseBin.path)")
            }

            let target = URL(fileURLWithPath: "/usr/local/bin/mkvql")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: releaseBin, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            print("Installed CLI to \(target.path)")
            print("You may need to restart your shell or run: hash -r")
        }
    }

    struct Upgrade: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Upgrade: pull latest sources (if git), rebuild, re-vendor, and replace the installed app.")

        @OptionGroup var options: MKVQL.Options

        func run() throws {
            let root = MKVQL.resolveSourceRoot(options.sourceRoot)

            // If this is a git checkout, pull
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
                print("Updating sources via git...")
                let (pullCode, pullOut) = try MKVQL.runShell("git pull --ff-only", cwd: root)
                if pullCode != 0 {
                    print("git pull warning: \(pullOut)")
                }
            }

            // Re-run the install logic (force)
            var opts = options
            opts.force = true
            // We call into the logic by exec-ing the same binary with install --force, but simpler to duplicate a bit.
            // For cleanliness, just call the build steps again.
            print("Rebuilding after upgrade...")
            // Re-execute via the same binary with "install --force" (cleaner than trying to share mutable state).
            // The wrapper/binary will handle the rest.


            // For simplicity in this build-out, invoke the Install flow by shelling back to ourselves if possible,
            // or just repeat the key steps.
            let installDir = options.installDir.map { URL(fileURLWithPath: $0) } ?? MKVQL.defaultInstallDir()
            // Trigger a fresh install (which will rebuild)
            let selfExe = URL(fileURLWithPath: CommandLine.arguments[0])
            let args = [selfExe.path, "install", "--force", "--source-root", root.path, "--install-dir", installDir.path]
            let p = Process()
            p.executableURL = selfExe
            p.arguments = Array(args.dropFirst())
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                throw ValidationError("Upgrade install step failed")
            }
            print("✅ Upgrade complete.")
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove the installed host app and (optionally) the CLI binary.")

        @OptionGroup var options: MKVQL.Options

        @Flag(help: "Also remove the mkvql binary from /usr/local/bin.")
        var removeCli: Bool = false

        func run() throws {
            let installDir = options.installDir.map { URL(fileURLWithPath: $0) } ?? MKVQL.defaultInstallDir()
            let app = MKVQL.installedAppURL(in: installDir)
            if FileManager.default.fileExists(atPath: app.path) {
                print("Removing \(app.path)")
                try FileManager.default.removeItem(at: app)
            } else {
                print("No app found at \(app.path)")
            }

            // Best effort unregister
            _ = try? MKVQL.runShell("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u \"\(app.path)\" 2>/dev/null || true")
            _ = try? MKVQL.runShell("qlmanage -r 2>/dev/null; qlmanage -r cache 2>/dev/null || true")

            if removeCli {
                let cli = URL(fileURLWithPath: "/usr/local/bin/mkvql")
                if FileManager.default.fileExists(atPath: cli.path) {
                    try FileManager.default.removeItem(at: cli)
                    print("Removed CLI at \(cli.path)")
                }
            }

            print("Uninstall complete. You may still have the source checkout at your original location.")
        }
    }

    struct Reconfigure: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change runtime settings (ffplay args, remux clip length, etc). No rebuild required.")

        @OptionGroup var options: MKVQL.Options

        @Option(name: .long, help: "Space-separated extra args for ffplay (quoted). Example: --ffplay-args \"-autoexit -volume 70\"")
        var ffplayArgs: String?

        @Option(name: .long, help: "Seconds to remux for native QL preview (0 = full file, fast copy). Example: --remux-seconds 60")
        var remuxSeconds: Double?

        @Flag(name: .long, help: "Enable automatic vendoring of current ffmpeg on next upgrade.")
        var autoVendor: Bool = false

        @Flag(name: .long, help: "Disable automatic vendoring.")
        var noAutoVendor: Bool = false

        func run() throws {
            var cfg = FFMPEGConfigBridge.load()

            if let argsStr = ffplayArgs {
                cfg.ffplayExtraArgs = argsStr.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            if let secs = remuxSeconds {
                cfg.remuxPreviewSeconds = secs
            }
            if autoVendor { cfg.autoVendorOnUpgrade = true }
            if noAutoVendor { cfg.autoVendorOnUpgrade = false }

            cfg.save()
            print("Saved config to \(MKVQLConfig.configURL.path)")
            print("  ffplayExtraArgs: \(cfg.ffplayExtraArgs)")
            print("  remuxPreviewSeconds: \(cfg.remuxPreviewSeconds)")
            print("  autoVendorOnUpgrade: \(cfg.autoVendorOnUpgrade)")
            print("\nChanges take effect immediately for new previews. Existing open QL windows may need close/reopen.")
        }
    }

    struct Doctor: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check that ffmpeg, ffplay, build tools, and registration look healthy.")

        func run() throws {
            print("Checking system tools...")
            for bin in ["ffmpeg", "ffplay", "ffprobe", "xcodegen", "xcodebuild", "swift"] {
                let (_, o) = try MKVQL.runShell("command -v \(bin) || echo 'MISSING'")
                let path = o.trimmingCharacters(in: .whitespacesAndNewlines)
                print("  \(bin): \(path)")
            }

            // Try to locate a source root with project
            let root = MKVQL.resolveSourceRoot(nil)
            let hasProj = FileManager.default.fileExists(atPath: root.appendingPathComponent("MKVQuickLook.xcodeproj").path)
            print("\nSource root guess: \(root.path)  (has .xcodeproj: \(hasProj))")

            let cfg = FFMPEGConfigBridge.load()
            print("\nConfig: \(cfg)")

            print("\nDoctor done. Run `mkvql install` or `mkvql upgrade` if anything is missing.")
        }
    }
}

// MARK: - Tiny bridge so the CLI can read/write the same config the app/extensions use
// (We duplicate the tiny Codable bits here so the CLI has zero dependency on the app sources at build time.)

struct MKVQLConfig: Codable, Equatable {
    var version: Int = 1
    var ffplayExtraArgs: [String] = ["-autoexit"]
    var remuxPreviewSeconds: Double = 0
    var autoVendorOnUpgrade: Bool = true

    static let configURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MKVQuickLook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.plist")
    }()

    static func load() -> MKVQLConfig {
        let url = configURL
        guard let data = try? Data(contentsOf: url),
              let c = try? PropertyListDecoder().decode(MKVQLConfig.self, from: data) else {
            return MKVQLConfig()
        }
        return c
    }

    func save() {
        do {
            let data = try PropertyListEncoder().encode(self)
            try data.write(to: Self.configURL, options: .atomic)
        } catch { fputs("config save error: \(error)\n", stderr) }
    }
}

enum FFMPEGConfigBridge {
    static func load() -> MKVQLConfig { MKVQLConfig.load() }
}
