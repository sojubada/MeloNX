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
        SDL_SetMainReady()
        SDL_SetiOSEventPump(true)          // SDL's "iOS" API covers tvOS as well
        _ = SDL_Init(SDL_INIT_EVENTS)

        TVMemory.raiseJetsamLimit()
        Self.setEmulatorEnvironment()
        TVPaths.prepare()                  // sets MELONX_BASE_DIR; must precede initialize()
        Ryujinx.initialize()
        Self.configureAudioSession()

        TVControllers.shared.start()

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = TVRootViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
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
        var values: [(String, String)] = [
            ("MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE", "32"),
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
            NSLog("[MeloNX tvOS] audio session: \(error.localizedDescription)")
        }
    }
}

/// Hosts the SwiftUI library and presents games full screen.
final class TVRootViewController: UIHostingController<AnyView> {
    init() {
        super.init(rootView: AnyView(EmptyView()))
        rootView = AnyView(TVLibraryView(launch: { [weak self] game in self?.present(game) }))
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func present(_ game: GameInfo) {
        guard presentedViewController == nil else { return }
        present(TVEmulationViewController(game: game), animated: true)
    }
}
