//
//  TVPaths.swift
//  MeloNX tvOS
//
//  Where everything lives on the Apple TV: inside the app's own data container,
//  laid out like the iOS app (MeloNX keeps everything in Documents/):
//
//      <container>/Documents/
//          roms/      ← put .nsp / .xci / .nro here (sub-folders are fine)
//          system/    ← prod.keys (and title.keys)
//          firmware/  ← firmware .zip or extracted folder, installed from the app
//          Logs/      ← tvos-app.log (launch steps), stdout.log (core output), Ryujinx logs
//          bis/, games/, profiles/ … ← created by the emulator
//
//  A file browser finds the container under
//  /var/mobile/Containers/Data/Application/<UUID>/ — the library screen shows the
//  full path. If Documents cannot be written, Library/Caches/MeloNX is used instead
//  (tvOS may purge Caches, so Documents is preferred).
//

import Foundation

enum TVPaths {
    /// Resolved once at launch by `prepare()`.
    private(set) static var root: URL = FileManager.default.temporaryDirectory

    static var roms: URL { root.appendingPathComponent("roms", isDirectory: true) }
    static var keys: URL { root.appendingPathComponent("system", isDirectory: true) }
    static var firmware: URL { root.appendingPathComponent("firmware", isDirectory: true) }
    static var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    static var prodKeys: URL { keys.appendingPathComponent("prod.keys") }

    /// Picks a writable data root, creates the folders the user fills in, opens
    /// the launch log, and hands the root to the C# core (AppDataManager reads
    /// MELONX_BASE_DIR). Runs first in didFinishLaunching, before SDL and the core.
    static func prepare() {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(docs)
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            candidates.append(caches.appendingPathComponent("MeloNX", isDirectory: true))
        }
        candidates.append(fm.temporaryDirectory.appendingPathComponent("MeloNX", isDirectory: true))

        root = candidates.first(where: isWritable) ?? candidates[candidates.count - 1]

        for dir in [roms, keys, firmware, logs] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        TVLog.open(logs)
        TVLog.write("---- launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?")), \(ProcessInfo.processInfo.operatingSystemVersionString)")
        TVLog.write("data root: \(root.path)")

        setenv("MELONX_BASE_DIR", root.path, 1)
    }

    private static func isWritable(_ dir: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let probe = dir.appendingPathComponent(".write-probe")
            try Data("ok".utf8).write(to: probe)
            try fm.removeItem(at: probe)
            return true
        } catch {
            NSLog("[MeloNX tvOS] not writable: %@ (%@)", dir.path, error.localizedDescription)
            return false
        }
    }

    static var hasProdKeys: Bool {
        FileManager.default.fileExists(atPath: prodKeys.path)
    }

    /// The first firmware candidate in `firmware/`: a .zip, or the folder itself
    /// when it holds extracted .nca files.
    static var firmwareCandidate: URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: firmware, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        if let zip = items.first(where: { $0.pathExtension.lowercased() == "zip" }) {
            return zip
        }
        if items.contains(where: { $0.pathExtension.lowercased() == "nca" }) {
            return firmware
        }
        // One sub-folder with the extracted firmware inside
        return items.first(where: { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).contains(where: { $0.lowercased().hasSuffix(".nca") })
        })
    }
}

/// iOS defines these next to RyujinxController (Core/RyujinxController.swift);
/// the reused ControllerMappingStore reads the mapping file from here.
extension URL {
    static var controllerMappingsURL: URL {
        TVPaths.root.appendingPathComponent("controllerMappings.json")
    }
}

// MARK: - Logging

/// The Apple TV has no console, so a failed run is diagnosed from two files:
///   Logs/tvos-app.log  launch steps, one line each, written with write(2) so the
///                      last line survives a crash; a fatal signal adds a line
///   Logs/stdout.log    stdout + stderr: core output and .NET fail-fast messages
nonisolated(unsafe) private var tvLogFD: Int32 = -1

private let tvFatalSignalHandler: @convention(c) (Int32) -> Void = { sig in
    // async-signal-safe: stack bytes + write(2), then the default action
    if tvLogFD >= 0 {
        // "FATAL signal NN\n"
        var line: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                   UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (70, 65, 84, 65, 76, 32, 115, 105, 103, 110, 97, 108, 32,
             UInt8(48 + (sig / 10) % 10), UInt8(48 + sig % 10), 10)
        withUnsafeBytes(of: &line) { _ = write(tvLogFD, $0.baseAddress, 16) }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

enum TVLog {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func open(_ dir: URL) {
        tvLogFD = Darwin.open(dir.appendingPathComponent("tvos-app.log").path, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        // Core output and .NET fatal errors go to stdout/stderr
        let out = Darwin.open(dir.appendingPathComponent("stdout.log").path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if out >= 0 {
            dup2(out, STDOUT_FILENO)
            dup2(out, STDERR_FILENO)
            setvbuf(stdout, nil, _IOLBF, 0)
            setvbuf(stderr, nil, _IONBF, 0)
            close(out)
        }

        // Installed before the core starts; the core and .NET install their own
        // handlers on top and chain to these only for faults they do not handle.
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig, tvFatalSignalHandler)
        }
    }

    static func write(_ message: String) {
        NSLog("[MeloNX tvOS] %@", message)
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard tvLogFD >= 0 else { return }
        _ = line.withCString { Darwin.write(tvLogFD, $0, strlen($0)) }
    }
}
