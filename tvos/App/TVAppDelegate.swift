//
//  TVAppDelegate.swift
//  MeloNX tvOS
//
//  Launch sequence, following AppDelegate in UI/MeloNXApp.swift:
//    SDL → MoltenVK / JIT environment → data root → Ryujinx.initialize()
//  with the iOS-only steps (JIT26 breakpoint handler, orientation, themes,
//  crash-handler UI) left out.
//

import UIKit
import SwiftUI
import AVFoundation
import Metal

@main
final class TVAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // First: data root + launch log, so every later step leaves a trace.
        TVPaths.prepare()                  // also sets MELONX_BASE_DIR for the core

        TVLog.write("step: SDL")
        SDL_SetMainReady()
        SDL_SetiOSEventPump(true)          // SDL's "iOS" API covers tvOS as well
        _ = SDL_Init(SDL_INIT_EVENTS)

        TVLog.write("step: memory")
        TVMemory.raiseJetsamLimit()
        Self.setEmulatorEnvironment()
        TVLog.write("JIT: debugged \(TVJIT.isDebugged), RW→RX \(TVJIT.isAvailable ? "ok" : "no")")

        TVLog.write("step: core initialize")
        Ryujinx.initialize()
        TVLog.write("core initialized, firmware '\(Ryujinx.installedFirmwareVersion)', prod.keys \(TVPaths.hasProdKeys)")

        TVTextInput.register()

        TVLog.write("step: audio, controllers, UI")
        Self.configureAudioSession()
        TVControllers.shared.start()

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = TVRootViewController()
        window.makeKeyAndVisible()
        self.window = window
        TVMenuMusic.shared.start()
        TVLog.write("launch complete")
        return true
    }

    /// Launched from the icon: no debugger yet, so ask TrollStore to attach
    /// (the iPad "Open with JIT" step, done for the user). Rate limited in TVJIT.
    func applicationDidBecomeActive(_ application: UIApplication) {
        TVMemory.raiseJetsamLimit("active")
        let ok = TVJIT.isAvailable
        TVLog.write("active; JIT \(ok ? "on" : "off")")
        if !ok { TVJIT.request(automatic: true) }
    }

    // Lifecycle lines: a game that vanishes with no crash report was either sent
    // to the background (tvOS then reclaims its memory silently) or exited.
    func applicationDidEnterBackground(_ application: UIApplication) {
        TVLog.write("background; available \(TVMemory.availableMB) MB")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        TVLog.write("foreground")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        TVLog.write("will terminate")
    }

    func applicationWillResignActive(_ application: UIApplication) {
        TVLog.write("resign active (menu/home/screensaver)")
        // Home button / screensaver: freeze the game behind the pause menu
        (window?.rootViewController?.presentedViewController as? TVEmulationViewController)?.showPauseMenu()
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        report_memory_pressure(0)
    }

    /// Same variables as initEnvironmentVariables() in UI/MeloNXApp.swift.
    /// HAS_TXM / DUAL_MAPPED_JIT stay 0: those are the iOS 26 debugger paths
    /// (BreakpointJIT). With dynamic-codesigning the core uses plain RW↔RX JIT.
    private static func setEmulatorEnvironment() {
        // Apple's Metal Performance HUD (FPS, frame/GPU time, memory) over the game,
        // like MeloNX on iPhone. Read by Metal when it starts, so the setting takes
        // effect at the next app launch.
        if TVSettings.shared.values.metalHUD {
            setenv("MTL_HUD_ENABLED", "1", 1)
        }
        // RAM swap: the core backs guest memory with swap files here (GuestMemorySwap.cs).
        // Read by the core when it starts, so the setting applies at the next launch.
        if TVSettings.shared.values.guestSwap {
            let swapDir = TVPaths.root.appendingPathComponent("swap", isDirectory: true)
            setenv("MELONX_GUEST_SWAP_DIR", swapDir.path, 1)
            let free = (try? swapDir.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? nil
            TVLog.write("RAM swap on: \(swapDir.path); disk free \(free.map { "\($0 / 1_048_576) MB" } ?? "?")")
        }
        var values: [(String, String)] = [
            ("MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE", "32"),
            // One failed Metal command buffer must not end the game: keep using the
            // device (the core then drops that frame, see VulkanException.cs).
            ("MVK_CONFIG_RESUME_LOST_DEVICE", "1"),
            // Keep the MSL source MoltenVK holds for every shader LZFSE-compressed
            // (several times smaller); it otherwise piles up in malloc on a 4 GB box.
            ("MVK_CONFIG_SHADER_COMPRESSION_ALGORITHM", "1"),
            // MoltenVK errors only: its warnings ("primitive restart", one per
            // pipeline) were written synchronously to stdout.log while compiling.
            ("MVK_CONFIG_LOG_LEVEL", TVSettings.shared.values.debugLogs ? "2" : "1"),
            ("HAS_TXM", "0"),
            ("DUAL_MAPPED_JIT", "0"),
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            let tier2 = device.argumentBuffersSupport.rawValue >= MTLArgumentBuffersTier.tier2.rawValue
            values.append(("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", tier2 ? "1" : "0"))
            if #available(tvOS 17, *) {
                values.append(("MVK_SUPPORTS_EXT_DYN_STATE", device.supportsFamily(.apple4) ? "1" : "0"))
            } else {
                values.append(("MVK_SUPPORTS_EXT_DYN_STATE", "0"))
            }
        }
        for (name, value) in values {
            setenv(name, value, 1)
        }
    }

    private static func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            TVLog.write("audio session: \(error.localizedDescription)")
        }
    }
}

/// Hosts the SwiftUI library and presents games full screen.
final class TVRootViewController: UIHostingController<AnyView> {
    init() {
        super.init(rootView: AnyView(EmptyView()))
        rootView = AnyView(TVHomeView(launch: { [weak self] game in self?.present(game) }))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func present(_ game: GameInfo) {
        guard presentedViewController == nil else { return }
        present(TVEmulationViewController(game: game), animated: true)
    }
}
