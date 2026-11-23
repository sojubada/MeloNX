//
//  TVEmulationViewController.swift
//  MeloNX tvOS
//
//  Full-screen game view.
//
//  The surface setup is MetalViewRepresentable.createView (UI/Emulation/Metal/
//  MetalView.swift): a CAMetalLayer view (TVMetalView) handed to the core, which
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
    private var metalView: TVMetalView!
    private var started = false
    private var pauseMenuShown = false
    private var cancellables: Set<AnyCancellable> = []
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?
    private var lowMemoryCancellable: AnyCancellable?
    private var stopStuckCancellable: AnyCancellable?

    /// The core did not finish shutting down; nothing more can run in this
    /// process safely, so offer to close the app (relaunch from the Home screen).
    private func showStopStuck() {
        if presentedViewController != nil { dismiss(animated: false) }
        controllerUserInteractionEnabled = true
        let alert = UIAlertController(title: "게임 종료가 끝나지 않습니다",
                                      message: "에뮬레이터가 정리 중에 멈췄습니다. 앱을 닫은 뒤 홈 화면에서 다시 실행해 주세요.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "앱 닫기", style: .destructive) { _ in
            TVLog.write("closing the app after a stuck stop")
            exit(0)
        })
        present(alert, animated: true)
    }

    private let lowMemoryLabel: UILabel = {
        let label = UILabel()
        label.text = "  메모리가 거의 다 찼습니다. 지금 게임에서 저장하세요 — 곧 종료될 수 있습니다.  "
        label.font = .systemFont(ofSize: 28, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        label.layer.cornerRadius = 12
        label.clipsToBounds = true
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    init(game: GameInfo) {
        self.game = game
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let view = TVMetalView(frame: UIScreen.main.bounds)
        view.backgroundColor = .black
        metalView = view
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        controllerUserInteractionEnabled = false

        view.addSubview(lowMemoryLabel)
        NSLayoutConstraint.activate([
            lowMemoryLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
            lowMemoryLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            lowMemoryLabel.heightAnchor.constraint(equalToConstant: 56),
        ])
        lowMemoryCancellable = TVEmulator.shared.$lowMemory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] low in self?.lowMemoryLabel.isHidden = !low }

        stopStuckCancellable = TVEmulator.shared.$stopStuck
            .receive(on: DispatchQueue.main)
            .filter { $0 }
            .sink { [weak self] _ in self?.showStopStuck() }

        let metalLayer = metalView.metalLayer
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.framebufferOnly = false
        metalView.pinScale()

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
        // A pad that turns off mid-game (battery) leaves its last input held; pause
        // instead, like the Switch does when a controller disconnects.
        disconnectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let pad = note.object as? GCController, pad.extendedGamepad != nil else { return }
            TVLog.write("controller disconnected during play: \(pad.vendorName ?? "?"); pausing")
            self?.showPauseMenu()
        }
    }

    deinit {
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) }
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
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

    // MARK: Menu button / leaving the screen

    // While the pause menu is up controllerUserInteractionEnabled is true, so a
    // quick second Menu press reached UIKit, whose default is to dismiss this
    // screen: the library came back with the game still running underneath and
    // every other game was refused as "already running". While a game runs, Menu
    // only ever opens the pause menu.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if TVEmulator.shared.isRunning, presses.contains(where: { $0.type == .menu }) {
            showPauseMenu()
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if TVEmulator.shared.isRunning, presses.contains(where: { $0.type == .menu }) { return }
        super.pressesEnded(presses, with: event)
    }

    // Safety net: if this screen goes away any other way, end the game with it.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed, TVEmulator.shared.isRunning {
            TVLog.write("emulation screen dismissed while running; stopping the game")
            TVEmulator.shared.stop()
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
        // No alert can be shown while another one is up or the view is off screen;
        // flagging the menu as shown anyway would leave the game paused with no menu.
        guard TVEmulator.shared.isRunning, !pauseMenuShown,
              presentedViewController == nil, view.window != nil else { return }
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

/// Plain CAMetalLayer view for the core's swapchain, held at 1080p.
/// An MTKView was reset to the screen scale once on screen, and MoltenVK then
/// built a 3840×2160 swapchain (device log), costing GPU memory and bandwidth
/// on a 4 GB Apple TV. tvOS upscales the 1080p output to the TV.
final class TVMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    func pinScale() {
        if contentScaleFactor != 1 { contentScaleFactor = 1 }
        metalLayer.contentsScale = 1
        let size = CGSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        pinScale()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pinScale()
    }
}
