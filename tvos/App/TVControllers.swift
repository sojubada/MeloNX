//
//  TVControllers.swift
//  MeloNX tvOS
//
//  Tracks connected game controllers and attaches them to the emulator.
//
//  Input itself is the iOS code, unchanged: every pad is wrapped in
//  Core/Controllers/NativeController.swift, which reads its mapping from
//  ControllerMappingStore and forwards buttons, sticks, gyro and rumble to the
//  core. What the iOS ControllerManager adds on top (virtual on-screen pad, Steam
//  controllers, in-game menu navigation, settings UI) has no place on a TV.
//
//  Only pads with an extended gamepad profile count. The Siri Remote is a micro
//  gamepad with two buttons and a touch surface — it cannot play Switch games, so
//  it is never attached to a player slot. It still navigates the menus and its
//  Menu button pauses a running game (see TVEmulationViewController).
//

import Foundation
import GameController
import Combine

final class TVControllers: ObservableObject {
    static let shared = TVControllers()

    /// Pads that can play, in connection order. Player 1 is the first one.
    @Published private(set) var gamepads: [NativeController] = []

    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        GCController.shouldMonitorBackgroundEvents = false

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })

        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        refresh()
    }

    var hasGamepad: Bool { !gamepads.isEmpty }

    var summary: String {
        gamepads.isEmpty ? "연결 안 됨" : gamepads.map(\.name).joined(separator: ", ")
    }

    /// Re-reads GCController.controllers(), keeping existing wrappers so a pad that
    /// stays connected keeps its pointer (the core identifies a pad by it).
    func refresh() {
        let connected = GCController.controllers().filter { $0.extendedGamepad != nil }

        let gone = gamepads.filter { pad in !connected.contains(where: { $0 === pad.nativeController }) }
        for pad in gone {
            pad.cleanup()
        }

        var kept = gamepads.filter { pad in connected.contains(where: { $0 === pad.nativeController }) }
        for controller in connected where !kept.contains(where: { $0.nativeController === controller }) {
            kept.append(NativeController(nativeController: controller))
        }

        for (index, pad) in kept.enumerated() {
            pad.nativeController?.playerIndex = GCControllerPlayerIndex(rawValue: min(index, 3)) ?? .indexUnset
        }

        gamepads = kept
        TVLog.write("controllers: \(GCController.controllers().map { "\($0.vendorName ?? "?")\($0.extendedGamepad != nil ? "[ext]" : "")" }.joined(separator: ", "))")

        if TVEmulator.shared.isRunning {
            attachAll()
        }
    }

    /// Detach everything, then attach pads to players 1…n with the controller type
    /// chosen in settings (Pro Controller by default)
    /// (the iOS default for every slot, see Options.controllerType1…8).
    func attachAll() {
        for pad in gamepads {
            Ryujinx.detachGamepad(pad.pointer)
        }
        let type: ControllerType = pick(TVSettings.shared.values.player1Type, .proController)
        let swapFaces = TVSettings.shared.values.swapFaceButtons
        for (index, pad) in gamepads.prefix(8).enumerated() {
            pad.controllerType = type
            pad.attach(index, controllerType: type)
            pad.applyMapping(Self.mapping(for: pad, swapFaceButtons: swapFaces))
        }
    }

    /// The saved mapping for this pad, with A↔B and X↔Y exchanged when asked: on an
    /// Xbox or PlayStation pad the Switch's A (confirm) then sits on the right-hand
    /// button, where it is on a Switch controller.
    static func mapping(for pad: NativeController, swapFaceButtons: Bool) -> ControllerMapping {
        var mapping = ControllerMappingStore.shared.mapping(for: pad)
        guard swapFaceButtons else { return mapping }
        let a = mapping[.A], b = mapping[.B]
        let x = mapping[.X], y = mapping[.Y]
        mapping[.A] = b
        mapping[.B] = a
        mapping[.X] = y
        mapping[.Y] = x
        return mapping
    }

    func detachAll() {
        for pad in gamepads {
            Ryujinx.detachGamepad(pad.pointer)
        }
    }
}
