//
//  TVEmulationViewController.swift
//  MeloNX tvOS
//
//  Full-screen game view.
//
//  The surface setup is MetalViewRepresentable.createView (UI/Emulation/Metal/
//  MetalView.swift): an MTKView whose CAMetalLayer is handed to the core, which
//  renders into it through MoltenVK. Touch handling is gone (no touch screen).
//
//  GCEventViewController with controllerUserInteractionEnabled = false keeps
//  controller presses away from UIKit. Without it the Menu button of every pad —
//  and of the Siri Remote — would exit the app to the Home screen mid-game.
//  Instead:
//    • Siri Remote Menu  → pause menu (Resume / Quit)
//    • Pad − + L R held together → the same pause menu
//

import UIKit
import MetalKit
import GameController
import Combine

final class TVEmulationViewController: GCEventViewController {
    private let game: GameInfo
    private var metalView: MTKView!
    private var started = false
    private var pauseMenuShown = false
    private var cancellables: Set<AnyCancellable> = []
    private var connectObserver: NSObjectProtocol?

    init(game: GameInfo) {
        self.game = game
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let view = MTKView(frame: UIScreen.main.bounds, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        view.framebufferOnly = false
        // Render the swapchain at 1080p; the Apple TV scales the output to 4K.
        // A 4K drawable would only cost GPU time for the final blit.
        view.contentScaleFactor = 1.0
        metalView = view
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        controllerUserInteractionEnabled = false

        guard let metalLayer = metalView.layer as? CAMetalLayer else {
            fatalError("[MeloNX tvOS] MTKView layer is not a CAMetalLayer")
        }
        if metalLayer.device == nil {
            metalLayer.device = MTLCreateSystemDefaultDevice()
        }
        metalLayer.contentsScale = 1.0

        Ryujinx.setNativeWindow(Unmanaged.passUnretained(metalLayer).toOpaque())

        TVEmulator.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .finished(_, let code) = state { self?.emulationEnded(code: code) }
            }
            .store(in: &cancellables)

        installPauseTriggers()
        connectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.installPauseTriggers()
        }
    }

    deinit {
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        Ryujinx.setViewSize(view.bounds)
        Ryujinx.setUnboundedPresentTargetFps(for: view.window?.screen)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true

        Ryujinx.setViewSize(view.bounds)
        Ryujinx.setUnboundedPresentTargetFps(for: view.window?.screen)

        do {
            try TVEmulator.shared.start(game)
        } catch let block as TVLaunchBlock {
            showMessage(block.title, block.message) { [weak self] in self?.dismiss(animated: true) }
        } catch {
            showMessage("시작할 수 없습니다", error.localizedDescription) { [weak self] in self?.dismiss(animated: true) }
        }
    }

    // MARK: Pause menu

    private func installPauseTriggers() {
        for controller in GCController.controllers() {
            if let pad = controller.extendedGamepad {
                // Profile-level handler: NativeController only sets per-element
                // handlers, so this one does not take input away from the game.
                pad.valueChangedHandler = { [weak self] pad, _ in
                    let combo = pad.buttonMenu.isPressed && (pad.buttonOptions?.isPressed ?? false)
                        && pad.leftShoulder.isPressed && pad.rightShoulder.isPressed
                    if combo {
                        DispatchQueue.main.async { self?.showPauseMenu() }
                    }
                }
            } else if let remote = controller.microGamepad {
                remote.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                    if pressed {
                        DispatchQueue.main.async { self?.showPauseMenu() }
                    }
                }
            }
        }
    }

    func showPauseMenu() {
        guard TVEmulator.shared.isRunning, !pauseMenuShown else { return }
        pauseMenuShown = true
        TVEmulator.shared.setPaused(true)
        controllerUserInteractionEnabled = true   // let the remote / pad drive the alert

        let alert = UIAlertController(title: game.titleName, message: "일시정지됨", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "계속하기", style: .cancel) { [weak self] _ in
            self?.resume()
        })
        alert.addAction(UIAlertAction(title: "게임 종료", style: .destructive) { [weak self] _ in
            self?.pauseMenuShown = false
            self?.controllerUserInteractionEnabled = false
            TVEmulator.shared.setPaused(false)
            TVEmulator.shared.stop()
        })
        present(alert, animated: true)
    }

    private func resume() {
        pauseMenuShown = false
        controllerUserInteractionEnabled = false
        TVEmulator.shared.setPaused(false)
    }

    // MARK: End

    private func emulationEnded(code: Int) {
        let finish = { [weak self] in
            guard let self else { return }
            TVEmulator.shared.acknowledgeFinished()
            self.dismiss(animated: true)
        }
        // Dismiss a pause menu that may still be on screen
        if presentedViewController != nil {
            dismiss(animated: false)
        }
        controllerUserInteractionEnabled = true
        if code == 0 {
            finish()
        } else {
            showMessage("에뮬레이터가 종료되었습니다 (코드 \(code))",
                        "로그: \(TVPaths.logs.path)", completion: finish)
        }
    }

    private func showMessage(_ title: String, _ message: String, completion: @escaping () -> Void) {
        controllerUserInteractionEnabled = true
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in completion() })
        present(alert, animated: true)
    }
}
