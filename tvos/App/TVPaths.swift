//
//  TVPaths.swift
//  MeloNX tvOS
//
//  Where everything lives on the Apple TV.
//
//  The TrollStore build runs without a sandbox container (no-container +
//  no-sandbox, the same entitlements Argo uses), so the data root can be a fixed,
//  easy-to-find folder that a file browser can write to:
//
//      /var/mobile/Media/MeloNX/
//          roms/      ← put .nsp / .xci / .nro here (sub-folders are fine)
//          system/    ← prod.keys (and title.keys)
//          firmware/  ← firmware .zip or extracted folder, installed from the app
//          Logs/      ← Ryujinx logs (read these when something fails)
//          bis/, games/, profiles/ … ← created by the emulator
//
//  If that folder cannot be written (for example the app was installed without
//  the no-sandbox entitlement) the app falls back to its own container.
//

import Foundation

enum TVPaths {
    static let preferredRoot = URL(fileURLWithPath: "/var/mobile/Media/MeloNX", isDirectory: true)

    /// Resolved once at launch by `prepare()`.
    private(set) static var root: URL = preferredRoot

    static var roms: URL { root.appendingPathComponent("roms", isDirectory: true) }
    static var keys: URL { root.appendingPathComponent("system", isDirectory: true) }
    static var firmware: URL { root.appendingPathComponent("firmware", isDirectory: true) }
    static var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    static var prodKeys: URL { keys.appendingPathComponent("prod.keys") }

    /// Picks a writable data root, creates the folders the user fills in, and
    /// hands the root to the C# core (AppDataManager reads MELONX_BASE_DIR).
    /// Must run before `Ryujinx.initialize()`.
    static func prepare() {
        let fm = FileManager.default
        var candidates = [preferredRoot]
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(docs.appendingPathComponent("MeloNX", isDirectory: true))
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            candidates.append(caches.appendingPathComponent("MeloNX", isDirectory: true))
        }

        root = candidates.first(where: isWritable) ?? preferredRoot

        for dir in [roms, keys, firmware, logs] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        setenv("MELONX_BASE_DIR", root.path, 1)
        NSLog("[MeloNX tvOS] data root: \(root.path)")
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
            NSLog("[MeloNX tvOS] not writable: \(dir.path) (\(error.localizedDescription))")
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
