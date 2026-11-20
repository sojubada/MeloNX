//
//  TVEmulator.swift
//  MeloNX tvOS
//
//  Game list, launch gate, and the emulation thread.
//
//  Mirrors RyujinxController.startGame (Core/RyujinxController.swift) without the
//  iOS-only parts: no RamDonor (raised jetsam limit instead), no per-game settings
//  UI, no AirPlay, no touch. Settings are the MeloNX defaults (Options.swift).
//

import Foundation
import Combine
import UIKit

enum TVLaunchBlock: Error, Equatable {
    case noJIT
    case noGamepad
    case noKeys
    case alreadyRunning

    var title: String {
        switch self {
        case .noJIT: return "JIT를 사용할 수 없습니다"
        case .noGamepad: return "게임패드를 연결하세요"
        case .noKeys: return "prod.keys가 없습니다"
        case .alreadyRunning: return "이미 실행 중입니다"
        }
    }

    var message: String {
        switch self {
        case .noJIT:
            return "TrollStore로 설치한 MeloNX.tipa만 JIT 권한(dynamic-codesigning)을 가집니다. TrollStore에서 다시 설치하세요."
        case .noGamepad:
            return "확장 게임패드(8BitDo, Xbox, DualSense 등)가 연결되어야 게임을 시작합니다. Siri Remote로는 플레이할 수 없습니다.\n설정 → 리모컨 및 기기 → 블루투스에서 연결하세요."
        case .noKeys:
            return "본인 기기에서 추출한 prod.keys를 다음 폴더 안에 넣고 새로고침하세요.\n\(TVPaths.documents.path)"
        case .alreadyRunning:
            return "실행 중인 게임을 먼저 종료하세요."
        }
    }
}

final class TVEmulator: ObservableObject {
    static let shared = TVEmulator()

    enum State: Equatable {
        case idle
        case running(GameInfo)
        case finished(GameInfo, code: Int)
    }

    @Published private(set) var games: [GameInfo] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var firmwareVersion: String = ""
    @Published private(set) var loading = false

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    private var threadActive = false

    private init() {}

    // MARK: Library

    func refresh() {
        loading = true
        TVPaths.importKeys()
        Ryujinx.reloadKeySet()
        firmwareVersion = Ryujinx.installedFirmwareVersion

        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.scan()
            DispatchQueue.main.async {
                self.games = found
                self.loading = false
            }
        }
    }

    /// Game files anywhere in Documents (and the data root). Only container formats:
    /// loose .nca files also exist inside the emulator's own bis/ folder.
    private static func scan() -> [GameInfo] {
        let exts: Set<String> = ["nsp", "xci", "nro"]
        let files = TVPaths.find(in: TVPaths.inputDirs) { exts.contains($0.pathExtension.lowercased()) }
        var result: [GameInfo] = []
        for url in files {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            result.append(Ryujinx.getGameInfo(arg0: handle.fileDescriptor, arg1: url.pathExtension as NSString, path: url))
        }
        TVLog.write("scan: \(result.count) game(s)")
        return result.sorted { $0.titleName.localizedCaseInsensitiveCompare($1.titleName) == .orderedAscending }
    }

    // MARK: Firmware

    func installFirmware(from url: URL, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                try Ryujinx.installFirmware(at: url.path)
            } catch FirmwareInstallationError.failedInstall(let message) {
                failure = message
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.firmwareVersion = Ryujinx.installedFirmwareVersion
                completion(failure)
            }
        }
    }

    // MARK: Launch

    /// Why a game cannot start right now, or nil when it can.
    func launchBlock() -> TVLaunchBlock? {
        if threadActive || isRunning { return .alreadyRunning }
        if !TVJIT.isAvailable { return .noJIT }
        if !TVControllers.shared.hasGamepad { return .noGamepad }
        if !TVPaths.hasProdKeys { return .noKeys }
        return nil
    }

    /// Starts the emulation thread. The caller must already have handed the
    /// CAMetalLayer to the core (TVEmulationViewController does that first).
    func start(_ game: GameInfo) throws {
        if let block = launchBlock() { throw block }

        var options = Options(inputPath: game.fileURL.path)
        options.memoryEnt = TVMemory.hasIncreasedLimitEntitlement
        options.backendThreading = .on                // as RyujinxController.startGame
        options.disableDockedMode = true              // handheld 720p: lighter for the Apple TV GPU
        options.resolveMultiplayerLanInterface()

        TVControllers.shared.attachAll()
        TVLog.write("start \(game.titleName) [\(game.titleId)] \(game.fileURL.lastPathComponent); pads: \(TVControllers.shared.summary); available \(TVMemory.availableMB) MB")

        threadActive = true
        state = .running(game)
        UIApplication.shared.isIdleTimerDisabled = true

        Thread.detachNewThread {
            Thread.current.name = "MeloNX emulation"
            let code = Ryujinx.mainRyu(options)
            TVLog.write("emulation ended with code \(code)")

            DispatchQueue.main.async {
                self.threadActive = false
                TVControllers.shared.detachAll()
                UIApplication.shared.isIdleTimerDisabled = false
                self.state = .finished(game, code: code)
            }
        }
    }

    func setPaused(_ paused: Bool) {
        guard isRunning else { return }
        Ryujinx.togglePauseEmulation(paused)
    }

    func stop() {
        guard isRunning else { return }
        Ryujinx.stopEmulation()
    }

    func acknowledgeFinished() {
        if case .finished = state { state = .idle }
    }
}
