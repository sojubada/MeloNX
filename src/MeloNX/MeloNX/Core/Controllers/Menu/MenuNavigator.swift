//
//  MenuNavigator.swift
//  MeloNX
//
//  Created by Stossy11 on 29/9/2026.
//

import Foundation
import Combine
import simd
import Melo_Controller


enum MenuNavigation {
    case up, down, left, right
    case confirm, cancel
}

@MainActor
final class MenuNavigator {
    private let stepThreshold: Float = 0.5
    private let rearmThreshold: Float = 0.3
    private let repeatDelay: TimeInterval = 0.2
    
    private var handler: ((MenuNavigation) -> Void)?
    private var attached: [NativeController] = []
    private var stickStates: [ObjectIdentifier: StickState] = [:]
    private var subscription: AnyCancellable?
    
    private struct StickState {
        var isCentred = true
        var lastStep: Date = .distantPast
    }
    
    
    private static let buttonEvents: [VirtualControllerButton: MenuNavigation] = [
        .dPadUp: .up,
        .dPadDown: .down,
        .dPadLeft: .left,
        .dPadRight: .right,
        .leftShoulder: .left,
        .rightShoulder: .right,
        .A: .confirm,
        .B: .cancel,
    ]
    
    deinit {
        for controller in attached {
            controller.endMenuNavigation()
        }
    }
    
    func start(_ onNavigate: @escaping (MenuNavigation) -> Void) {
        handler = onNavigate
        
        guard subscription == nil else { return }
        
        
        subscription = ControllerManager.shared.$allControllers
            .sink { [weak self] controllers in
                self?.attach(to: controllers)
            }
    }
    
    
    func stop() {
        subscription = nil
        handler = nil
        
        for controller in attached {
            controller.endMenuNavigation()
        }
        
        attached = []
        stickStates = [:]
    }
    
    private func attach(to controllers: [BaseController]) {
        let natives = controllers.compactMap { $0 as? NativeController }
        
        for controller in attached where !natives.contains(where: { $0 === controller }) {
            controller.endMenuNavigation()
            
            stickStates.removeValue(forKey: ObjectIdentifier(controller))
        }
        
        for controller in natives where !attached.contains(where: { $0 === controller }) {
            controller.beginMenuNavigation { [weak self, weak controller] input in
                guard let self, let controller else { return }
                
                self.handle(input, from: controller)
            }
        }
        
        attached = natives
    }
    
    private func handle(_ input: MenuInput, from controller: NativeController) {
        guard let handler else { return }
        
        switch input {
        case .button(let button):
            guard let event = Self.buttonEvents[button] else { return }
            
            handler(event)
            
        case .stick(let stick, let value):
            guard stick == .left, let event = step(value, for: controller) else { return }
            
            handler(event)
        }
    }
    
    private func step(_ value: SIMD2<Float>, for controller: NativeController) -> MenuNavigation? {
        let key = ObjectIdentifier(controller)
        var state = stickStates[key] ?? StickState()
        
        defer { stickStates[key] = state }
        
        let reading = abs(value.x) >= abs(value.y) ? value.x : value.y
        
        guard abs(reading) >= stepThreshold else {
            if abs(value.x) < rearmThreshold && abs(value.y) < rearmThreshold {
                state.isCentred = true
            }
            
            return nil
        }
        
        let now = Date()
        
        guard state.isCentred || now.timeIntervalSince(state.lastStep) >= repeatDelay else { return nil }
        
        state.isCentred = false
        state.lastStep = now
        
        if abs(value.x) >= abs(value.y) {
            return reading < 0 ? .left : .right
        }
        
        return reading > 0 ? .up : .down
    }
}
