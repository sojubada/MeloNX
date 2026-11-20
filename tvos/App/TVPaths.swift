//
//  TVPaths.swift
//  MeloNX tvOS
//
//  Where everything lives. The tvOS sandbox denies an app its own Documents/
//  (device log: "app can write: false", files there invisible), and the
//  no-sandbox entitlement did not work, so the upstream MeloNX layout is kept
//  under Library/Caches/MeloNX instead of Documents:
//
//      <container>/Library/Caches/MeloNX/
//          roms/      ← games .nsp / .xci / .nro (sub-folders are fine)
//          system/    ← prod.keys, title.keys
//          firmware/  ← firmware .zip (installed from the home screen)
//          Logs/      ← tvos-app.log, stdout.log (+ stdout.prev.log = previous run)
//          bis/, games/, profiles/ … ← created by the emulator
//
//  Documents is still tried first, in case a future tvOS / install allows it.
//

import Foundation

enum TVPaths {
    /// The app container's Documents. tvOS lets a file browser (Argo) write here
    /// but may refuse writes from the app itself, so it is treated as input only:
    /// games, prod.keys / title.keys and firmware .zip can go anywhere inside it.
    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")

    /// Emulator data root (keys copy, firmware, saves, logs). Documents when the app
    /// can write it, otherwise Library/Caches/MeloNX. Resolved by `prepare()`.
    private(set) static var root: URL = FileManager.default.temporaryDirectory

    static var roms: URL { root.appendingPathComponent("roms", isDirectory: true) }
    static var keys: URL { root.appendingPathComponent("system", isDirectory: true) }
    static var firmware: URL { root.appendingPathComponent("firmware", isDirectory: true) }
    static var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    static var prodKeys: URL { keys.appendingPathComponent("prod.keys") }

    /// Library/Caches/MeloNX: data root of builds 16–21; still searched so files
    /// copied there keep working.
    static let legacyRoot: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("MeloNX", isDirectory: true)

    /// Folders searched for games, keys and firmware.
    static var inputDirs: [URL] {
        var dirs = [root]
        for d in [documents, legacyRoot].compactMap({ $0 })
            where !dirs.contains(where: { $0.standardizedFileURL == d.standardizedFileURL })
            && FileManager.default.fileExists(atPath: d.path) {
            dirs.append(d)
        }
        return dirs
    }

    /// Runs first in didFinishLaunching, before SDL and the core.
    static func prepare() {
        let fm = FileManager.default
        var candidates = [documents]
        if let legacyRoot { candidates.append(legacyRoot) }
        candidates.append(fm.temporaryDirectory.appendingPathComponent("MeloNX", isDirectory: true))
        root = candidates.first(where: isWritable) ?? candidates[candidates.count - 1]

        for dir in [roms, keys, firmware, logs] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        TVLog.open(logs)
        TVLog.write("---- launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?")), \(ProcessInfo.processInfo.operatingSystemVersionString)")
        TVLog.write("documents: \(documents.path) (app can write: \(root.standardizedFileURL == documents.standardizedFileURL))")
        TVLog.write("data root: \(root.path)")

        importKeys()
        setenv("MELONX_BASE_DIR", root.path, 1)
    }

    /// The core reads keys only from <root>/system (AppDataManager.KeysDirPath).
    /// If prod.keys / title.keys were put somewhere else in the input folders
    /// (e.g. Documents/ itself), copy them there.
    static func importKeys() {
        let fm = FileManager.default
        for name in ["prod.keys", "title.keys"] {
            if fm.fileExists(atPath: keys.appendingPathComponent(name).path) { continue }
            let others = inputDirs.flatMap { [$0.appendingPathComponent("system").appendingPathComponent(name)] }
            let direct = others.first { fm.fileExists(atPath: $0.path) }
            guard let found = direct ?? find(in: inputDirs, where: { $0.lastPathComponent.lowercased() == name }).first else { continue }
            let dest = keys.appendingPathComponent(name)
            if found.standardizedFileURL == dest.standardizedFileURL { continue }
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: found, to: dest)
                TVLog.write("keys: copied \(found.path)")
            } catch {
                TVLog.write("keys: copy failed \(found.path): \(error.localizedDescription)")
            }
        }
    }

    /// Recursive search, skipping the emulator's own folders.
    static func find(in dirs: [URL], where match: (URL) -> Bool) -> [URL] {
        let skip: Set<String> = ["bis", "games", "profiles", "sdcard", "Logs", "mods", "config", "system"]
        var result: [URL] = []
        for dir in dirs {
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if skip.contains(url.lastPathComponent)
                        && url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL {
                        e.skipDescendants()
                    }
                    continue
                }
                if match(url) { result.append(url) }
            }
        }
        return result
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

    /// A firmware .zip anywhere in the input folders, or the extracted folder
    /// <root>/firmware when it holds .nca files.
    static var firmwareCandidate: URL? {
        if let zip = find(in: inputDirs, where: { $0.pathExtension.lowercased() == "zip" }).first {
            return zip
        }
        let ncas = (try? FileManager.default.contentsOfDirectory(atPath: firmware.path)) ?? []
        return ncas.contains(where: { $0.lowercased().hasSuffix(".nca") }) ? firmware : nil
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
        // Keep the previous run: after a crash the app is relaunched to read the log
        let stdoutPath = dir.appendingPathComponent("stdout.log").path
        let prevPath = dir.appendingPathComponent("stdout.prev.log").path
        Darwin.unlink(prevPath)
        Darwin.rename(stdoutPath, prevPath)
        let out = Darwin.open(stdoutPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
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
