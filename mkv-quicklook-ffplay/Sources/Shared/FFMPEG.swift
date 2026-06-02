import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Locates and runs the user's ffmpeg/ffplay/ffprobe.
/// Prefers a setting stored via app group or UserDefaults.
/// Tries bundled copies (great for sandboxed extensions), then common install paths.
/// Also provides helpers for remux (to enable native AV playback) and frame extraction.
public enum FFMPEG {
    public static let appGroup = "group.com.qbit.mkvquicklook"

    public static let defaultFFmpegPaths = [
        "/usr/local/bin/ffmpeg",
        "/opt/homebrew/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]
    public static let defaultFFplayPaths = [
        "/usr/local/bin/ffplay",
        "/opt/homebrew/bin/ffplay",
        "/usr/bin/ffplay"
    ]

    // MARK: - Path resolution (shared via suite when possible)

    public static func ffmpegURL() -> URL? {
        if let fromDefaults = userDefaults().string(forKey: "ffmpegPath"),
           FileManager.default.isExecutableFile(atPath: fromDefaults) {
            return URL(fileURLWithPath: fromDefaults)
        }
        // bundled inside app or extension container
        if let bundled = bundledTool(name: "ffmpeg") {
            return bundled
        }
        for p in defaultFFmpegPaths where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    public static func ffplayURL() -> URL? {
        if let fromDefaults = userDefaults().string(forKey: "ffplayPath"),
           FileManager.default.isExecutableFile(atPath: fromDefaults) {
            return URL(fileURLWithPath: fromDefaults)
        }
        if let bundled = bundledTool(name: "ffplay") {
            return bundled
        }
        for p in defaultFFplayPaths where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    public static func ffprobeURL() -> URL? {
        // derive from ffmpeg if possible
        if let ff = ffmpegURL() {
            let probe = ff.deletingLastPathComponent().appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: probe.path) {
                return probe
            }
        }
        if let bundled = bundledTool(name: "ffprobe") { return bundled }
        if let ff = ffmpegURL() {
            // last attempt: same dir
            let candidate = ff.deletingLastPathComponent().appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func bundledTool(name: String) -> URL? {
        let fm = FileManager.default
        // When running from extension, Bundle.main is the appex. Go up to the app.
        var candidates: [URL] = []
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/\(name)"))
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)"))
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Contents/Resources/bin/\(name)"))

        for u in candidates {
            if fm.isExecutableFile(atPath: u.path) { return u }
        }
        // Also check inside the main app bundle for Resources (for when code is in app target)
        if let res = Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)"),
           fm.isExecutableFile(atPath: res.path) {
            return res
        }
        return nil
    }

    private static func userDefaults() -> UserDefaults {
        if let suite = UserDefaults(suiteName: appGroup) {
            return suite
        }
        return .standard
    }

    public static func setFFmpegPath(_ path: String) {
        userDefaults().set(path, forKey: "ffmpegPath")
    }
    public static func setFFplayPath(_ path: String) {
        userDefaults().set(path, forKey: "ffplayPath")
    }

    // MARK: - Execution

    public static func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 30) -> (exitCode: Int32, stdout: Data, stderr: Data)? {
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            NSLog("FFMPEG: failed to launch \(executable.path): \(error)")
            return nil
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        return (task.terminationStatus, outData, errData)
    }

    /// Extract a single frame as JPEG data. Returns nil on failure.
    public static func extractFrame(from mkv: URL, at seconds: Double = 10.0, maxWidth: Int = 640) -> Data? {
        guard let ff = ffmpegURL() else { return nil }

        // Use fast seek + thumbnail filter for a representative frame.
        // -ss before -i for fast seek on most files.
        let args = [
            "-hide_banner", "-loglevel", "error",
            "-ss", String(format: "%.2f", max(0, seconds)),
            "-i", mkv.path,
            "-vf", "thumbnail,scale='min(\(maxWidth),iw)':'-1'",
            "-frames:v", "1",
            "-f", "mjpeg",
            "-"
        ]

        if let res = run(ff, arguments: args, timeout: 20), res.exitCode == 0, !res.stdout.isEmpty {
            return res.stdout
        }
        return nil
    }

    /// Fast remux to a temp .mp4 (or .mov). Uses -c copy when possible.
    /// Returns the temp URL or nil.
    /// The caller is responsible for cleanup (or it lives in NSTemporaryDirectory until reboot).
    public static func remuxToMP4(source: URL, durationLimit: TimeInterval? = nil) -> URL? {
        guard let ff = ffmpegURL() else { return nil }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mkvql-\(UUID().uuidString).mp4")

        var args = [
            "-hide_banner", "-loglevel", "error",
            "-i", source.path,
            "-c", "copy",
            "-movflags", "+faststart",
            "-y"
        ]
        if let limit = durationLimit, limit > 0 {
            args.insert(contentsOf: ["-t", String(format: "%.1f", limit)], at: 1)
        }
        args.append(tmp.path)

        guard let res = run(ff, arguments: args, timeout: 120) else { return nil }
        if res.exitCode == 0, FileManager.default.fileExists(atPath: tmp.path) {
            return tmp
        }
        // cleanup partial
        try? FileManager.default.removeItem(at: tmp)
        return nil
    }

    // MARK: - ffplay launch (best effort, called from main app via URL scheme)

    public static func launchFFPlay(on file: URL, extraArgs: [String] = []) {
        guard let player = ffplayURL() else {
            // Fallback: just reveal or open with default
            #if canImport(AppKit)
            NSWorkspace.shared.activateFileViewerSelecting([file])
            #endif
            return
        }

        var args: [String] = []
        // Sensible defaults for preview-like usage. User can customize.
        args += ["-autoexit", "-window_title", "ffplay: \(file.lastPathComponent)"]
        if !extraArgs.isEmpty {
            args += extraArgs
        }
        args.append(file.path)

        let task = Process()
        task.executableURL = player
        task.arguments = args
        // Detach so ffplay lives on its own
        task.standardOutput = nil
        task.standardError = nil

        do {
            try task.run()
            // Do not wait
        } catch {
            NSLog("Failed to launch ffplay: \(error)")
            // Last resort
            #if canImport(AppKit)
            NSWorkspace.shared.open(file)
            #endif
        }
    }

    /// Ask ffprobe (if present) for codec info string.
    public static func probeCodecs(for file: URL) -> String? {
        guard let probe = ffprobeURL() else { return nil }
        let args = ["-hide_banner", "-loglevel", "error", "-show_streams", "-print_format", "json", file.path]
        guard let res = run(probe, arguments: args, timeout: 15),
              res.exitCode == 0,
              let json = try? JSONSerialization.jsonObject(with: res.stdout) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]] else {
            return nil
        }
        let parts = streams.compactMap { s -> String? in
            let codec = s["codec_name"] as? String ?? "?"
            let type = s["codec_type"] as? String ?? "?"
            return "\(type):\(codec)"
        }
        return parts.joined(separator: ", ")
    }
}


// MARK: - Reconfigurable settings (driven by the mkvql CLI tool)
// Stored in a simple plist so both the host app, CLI, and sandboxed extensions can read it without running a daemon.

public struct MKVQLConfig: Codable, Equatable {
    public var version: Int = 1
    /// Extra arguments always passed to ffplay (e.g. ["-volume", "80", "-autoexit"])
    public var ffplayExtraArgs: [String] = ["-autoexit"]
    /// When > 0, the QL preview will only remux the first N seconds to a temp mp4 for native playback.
    /// 0 (or negative) = remux the entire file (fast copy, but uses disk = file size).
    public var remuxPreviewSeconds: Double = 0
    /// Whether to attempt to vendor the current system ffmpeg/ffplay at the next upgrade/install.
    public var autoVendorOnUpgrade: Bool = true

    public static let currentVersion = 1
    public static let configURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MKVQuickLook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.plist")
    }()

    public static func load() -> MKVQLConfig {
        let url = configURL
        guard let data = try? Data(contentsOf: url),
              let cfg = try? PropertyListDecoder().decode(MKVQLConfig.self, from: data) else {
            return .default()
        }
        return cfg
    }

    public static func `default`() -> MKVQLConfig { MKVQLConfig() }

    public func save() {
        let url = Self.configURL
        do {
            let data = try PropertyListEncoder().encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Failed to save MKVQLConfig: \(error)")
        }
    }
}

public extension FFMPEG {
    /// Read the user-reconfigurable config (CLI is the primary editor).
    static func config() -> MKVQLConfig {
        MKVQLConfig.load()
    }

    /// Convenience: the extra args the user (via CLI) wants for every ffplay launch.
    static func ffplayExtraArgs() -> [String] {
        config().ffplayExtraArgs
    }

    /// How long (seconds) to remux for the in-QL native player preview. 0 = full file.
    static func remuxLimitSeconds() -> Double? {
        let s = config().remuxPreviewSeconds
        return s > 0 ? s : nil
    }
}

// Update the launch helper to respect the current config automatically.
public extension FFMPEG {
    /// Launch ffplay using the vendored (or system) binary + the user config's extra args.
    static func launchFFPlayConfigured(on file: URL) {
        let extra = ffplayExtraArgs()
        launchFFPlay(on: file, extraArgs: extra)
    }
}
