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
//          Logs/      ← tvos-app.log, stdout.log (+ stdout.prev…prev4.log = earlier runs)
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

// Crash line for a fatal signal: signal, fault address, pc/lr with the image
// they fall in (image + offset), then the call stack. Only stack buffers and
// write(2) for the first lines; dladdr/backtrace are not async-signal-safe but
// the process is about to die anyway and this is the only record tvOS leaves.
nonisolated private func tvWrite(_ s: StaticString) {
    _ = write(tvLogFD, s.utf8Start, s.utf8CodeUnitCount)
}

nonisolated private func tvWriteHex(_ value: UInt64) {
    var buf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
              UInt8, UInt8) = (48, 120, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    withUnsafeMutableBytes(of: &buf) { p in
        for i in 0..<16 {
            let nibble = UInt8((value >> UInt64((15 - i) * 4)) & 0xF)
            p[2 + i] = nibble < 10 ? 48 + nibble : 87 + nibble
        }
        _ = write(tvLogFD, p.baseAddress, 18)
    }
}

nonisolated private func tvWriteImage(_ address: UInt64) {
    var info = Dl_info()
    guard address != 0, let ptr = UnsafeRawPointer(bitPattern: UInt(address)),
          dladdr(ptr, &info) != 0, let name = info.dli_fname else { return }
    tvWrite(" in ")
    // last path component of the image
    var start = name
    var p = name
    while p.pointee != 0 { if p.pointee == 47 { start = p + 1 }; p += 1 }
    _ = write(tvLogFD, start, strlen(start))
    tvWrite(" +")
    tvWriteHex(address &- UInt64(UInt(bitPattern: info.dli_fbase)))
}

private let tvFatalSignalHandler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { sig, info, uc in
    if tvLogFD >= 0 {
        // "FATAL signal NN"
        var line: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                   UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (70, 65, 84, 65, 76, 32, 115, 105, 103, 110, 97, 108, 32,
             UInt8(48 + (sig / 10) % 10), UInt8(48 + sig % 10))
        withUnsafeBytes(of: &line) { _ = write(tvLogFD, $0.baseAddress, 15) }

        if let info {
            tvWrite(" addr ")
            tvWriteHex(UInt64(UInt(bitPattern: info.pointee.si_addr)))
        }
        if let uc, let mc = uc.assumingMemoryBound(to: ucontext_t.self).pointee.uc_mcontext {
            let pc = mc.pointee.__ss.__pc
            let lr = mc.pointee.__ss.__lr
            tvWrite("\n  pc ")
            tvWriteHex(pc)
            tvWriteImage(pc)
            tvWrite("\n  lr ")
            tvWriteHex(lr)
            tvWriteImage(lr)
        }
        tvWrite("\n  stack:\n")
        withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 48) { frames in
            let n = backtrace(frames.baseAddress, 48)
            backtrace_symbols_fd(frames.baseAddress, n, tvLogFD)
        }
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
        // Keep the last four runs (stdout.prev.log = previous, then prev2...prev4):
        // after a freeze the app is often relaunched more than once before the
        // logs are collected, and one previous run was not enough.
        let stdoutPath = dir.appendingPathComponent("stdout.log").path
        let previous = ["stdout.prev.log", "stdout.prev2.log", "stdout.prev3.log", "stdout.prev4.log"]
            .map { dir.appendingPathComponent($0).path }
        Darwin.unlink(previous[previous.count - 1])
        for i in stride(from: previous.count - 1, to: 0, by: -1) {
            Darwin.rename(previous[i - 1], previous[i])
        }
        Darwin.rename(stdoutPath, previous[0])
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
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = tvFatalSignalHandler
            action.sa_flags = SA_SIGINFO
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
    }

    static func write(_ message: String) {
        NSLog("[MeloNX tvOS] %@", message)
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard tvLogFD >= 0 else { return }
        _ = line.withCString { Darwin.write(tvLogFD, $0, strlen($0)) }
    }
}
