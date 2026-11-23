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
    case noFirmware
    case alreadyRunning

    var title: String {
        switch self {
        case .noJIT: return "JIT를 사용할 수 없습니다"
        case .noGamepad: return "게임패드를 연결하세요"
        case .noKeys: return "prod.keys가 없습니다"
        case .noFirmware: return "펌웨어가 설치되지 않았습니다"
        case .alreadyRunning: return "이미 실행 중입니다"
        }
    }

    var message: String {
        switch self {
        case .noJIT:
            return "TrollStore 앱 목록에서 MeloNX를 고른 뒤 \"Open with JIT\"로 실행하세요.\n(홈 화면의 \"JIT 켜기\" 버튼은 TrollStore에 같은 요청을 보냅니다.)"
        case .noGamepad:
            return "확장 게임패드(8BitDo, Xbox, DualSense 등)가 연결되어야 게임을 시작합니다. Siri Remote로는 플레이할 수 없습니다.\n설정 → 리모컨 및 기기 → 블루투스에서 연결하세요."
        case .noKeys:
            return "본인 기기에서 추출한 prod.keys를 다음 폴더에 넣고 새로고침하세요.\n\(TVPaths.keys.path)"
        case .noFirmware:
            return "게임은 펌웨어의 시스템 폰트·시간대 데이터가 있어야 시작됩니다(없으면 앱이 종료됩니다).\n본인 기기에서 덤프한 펌웨어 .zip을 \(TVPaths.firmware.path)에 넣고 홈 화면의 \"펌웨어 설치\"를 누르세요."
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
    /// Under ~300 MB left the game is close to being closed by tvOS: the game
    /// screen shows a "save now" hint (TVEmulationViewController).
    @Published private(set) var lowMemory = false
    /// Set when a quit did not finish in time (the core's teardown can hang); the
    /// emulation screen then offers to close the app instead of sitting on black.
    @Published private(set) var stopStuck = false
    static let lowMemoryMB = 300

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    private var threadActive = false
    private var memoryWatch: DispatchSourceTimer?

    /// RunningBoard may lower the limit again while the game runs; put it back.
    private func startMemoryWatch() {
        memoryWatch?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)   // RunningBoard can lower the limit at any time; keep the window short
        var ticks = 0
        timer.setEventHandler {
            TVMemory.raiseJetsamLimit("watch")
            ticks += 1
            // Every 30 s: a game killed by jetsam leaves no crash line, so the
            // last of these shows how close it was.
            let available = TVMemory.availableMB
            if ticks % 30 == 0 {
                // footprint = everything charged to the app; Metal = GPU share of it
                TVLog.write("mem: available \(available) MB, footprint \(TVMemory.footprintMB) MB, Metal \(TVMemory.metalMB) MB; \(TVMemory.ledgerSummary)")
            }
            // What the footprint is made of: at 5 s (after loading), every 30 s, and when it gets low
            if ticks == 5 || ticks % 30 == 15 || (available < Self.lowMemoryMB && !self.lowMemory) {
                DispatchQueue.global(qos: .utility).async { TVLog.write(TVMemory.regionSummary()) }
            }
            // tvOS sends no system memory-pressure event while we are under our own
            // raised limit, so the GPU caches were never trimmed (log: GPU memory
            // +375 MB in 90 s, no trim). Report it ourselves; the core throttles
            // trims to one per 2 s and only evicts textures not in use.
            if available < 700 {
                report_memory_pressure(available < 400 ? 1 : 0)
            }
            let low = available < Self.lowMemoryMB
            if low != self.lowMemory {
                self.lowMemory = low
                TVLog.write(low ? "low memory warning shown (\(available) MB)" : "low memory warning cleared")
            }
        }
        timer.resume()
        memoryWatch = timer
    }

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

    /// Game files in roms/ (or anywhere else in the input folders). Only container formats:
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
        if firmwareVersion.isEmpty { return .noFirmware }
        return nil
    }

    /// Starts the emulation thread. The caller must already have handed the
    /// CAMetalLayer to the core (TVEmulationViewController does that first).
    func start(_ game: GameInfo) throws {
        if let block = launchBlock() { throw block }

        var options = Options(inputPath: game.fileURL.path)
        TVSettings.shared.apply(to: &options)        // settings screen (TVSettingsView)
        options.memoryEnt = TVMemory.hasIncreasedLimitEntitlement
        options.resolveMultiplayerLanInterface()

        TVControllers.shared.attachAll()
        TVMemory.raiseJetsamLimit("game start")
        startMemoryWatch()
        TVLog.write("start \(game.titleName) [\(game.titleId)] \(game.fileURL.lastPathComponent); pads: \(TVControllers.shared.summary); available \(TVMemory.availableMB) MB")

        threadActive = true
        state = .running(game)
        UIApplication.shared.isIdleTimerDisabled = true

        Thread.detachNewThread {
            Thread.current.name = "MeloNX emulation"
            let code = Ryujinx.mainRyu(options)
            TVLog.write("emulation ended with code \(code)")

            DispatchQueue.main.async {
                self.memoryWatch?.cancel()
                self.memoryWatch = nil
                self.lowMemory = false
                self.threadActive = false
                self.stopStuck = false
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
        TVLog.write("stop requested")
        Ryujinx.stopEmulation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.threadActive else { return }
            TVLog.write("emulation did not end 15 s after stop")
            self.stopStuck = true
        }
    }

    func acknowledgeFinished() {
        if case .finished = state { state = .idle }
    }
}
