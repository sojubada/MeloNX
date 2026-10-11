//
//  NativeController.swift
//  MeloNX
//
//  Created by Stossy11 on 19/10/2025.
//

import Foundation
import CoreHaptics
import UIKit
import GameController
import Melo_Controller
import simd

enum CapturedInput {
    case button(PhysicalInput)
    case stick(PhysicalStick)
}

enum MenuInput {
    case button(VirtualControllerButton)
    case stick(ThumbstickType, SIMD2<Float>)
}

class NativeController: BaseController {
    override init(nativeController: GCController?, virtual: Bool? = nil) {
        super.init(nativeController: nativeController)
    }
    
    private(set) var activeMapping: ControllerMapping = .standard()
    
    private var captureHandler: ((CapturedInput) -> Void)?
    private var menuHandler: ((MenuInput) -> Void)?
    
    private var profile: GCPhysicalInputProfile? {
        nativeController?.extendedGamepad ?? nativeController?.physicalInputProfile
    }
    
    override public func setupController() {
        menuHandler = nil
        
        applyMapping(ControllerMappingStore.shared.mapping(for: self))
        
        setupHaptics()
        
        setupMotion()
    }
    
    func refreshMotion() {
        stopMotion()
        
        setupMotion()
    }
    
    func applyMapping(_ mapping: ControllerMapping) {
        activeMapping = mapping
        
        nativeController?.handlerQueue = inputQueue
        
        clearInputHandlers()
        
        if menuHandler != nil {
            installMenuHandlers(mapping)
        } else {
            installButtonHandlers(mapping)
            installStickHandlers(mapping)
        }
    }
    
    private func installButtonHandlers(_ mapping: ControllerMapping) {
        for input in PhysicalInput.allCases where input != .unbound {
            let targets = mapping.emulatedButtons(for: input)
            
            guard !targets.isEmpty, let element = buttonElement(for: input) else { continue }
            
            let threshold = mapping.triggerThreshold
            
            element.valueChangedHandler = { [weak self] _, value, pressed in
                guard let self else { return }
                
                let isDown = input.isTrigger ? value >= threshold : pressed
                
                for target in targets {
                    self.setButtonState(isDown ? 1 : 0, for: target)
                }
            }
        }
    }
    
    private func installStickHandlers(_ mapping: ControllerMapping) {
        
        var feeds: [PhysicalStick: [(axis: Int, config: StickMapping)]] = [:]
        
        for (axis, config) in [(1, mapping.leftStick), (2, mapping.rightStick)] {
            guard config.source != .unbound else { continue }
            
            feeds[config.source, default: []].append((axis, config))
        }
        
        for (source, targets) in feeds {
            guard let element = stickElement(for: source) else { continue }
            
            element.valueChangedHandler = { [weak self] _, xValue, yValue in
                guard let self else { return }
                
                for target in targets {
                    let value = target.config.apply(x: xValue, y: yValue)
                    
                    self.updateAxisValue(x: value.x, y: value.y, forAxis: target.axis)
                }
            }
        }
    }
    
    private func buttonElement(for input: PhysicalInput) -> GCControllerButtonInput? {
        guard let profile else { return nil }
        
        switch input {
        case .dpadUp: return dpadElement?.up
        case .dpadDown: return dpadElement?.down
        case .dpadLeft: return dpadElement?.left
        case .dpadRight: return dpadElement?.right
        default:
            guard let name = input.gcButtonName else { return nil }
            
            return profile.buttons[name]
        }
    }
    
    private var dpadElement: GCControllerDirectionPad? {
        nativeController?.extendedGamepad?.dpad ?? profile?.dpads[GCInputDirectionPad]
    }
    
    private func stickElement(for stick: PhysicalStick) -> GCControllerDirectionPad? {
        switch stick {
        case .left:
            return nativeController?.extendedGamepad?.leftThumbstick ?? profile?.dpads[GCInputLeftThumbstick]
        case .right:
            return nativeController?.extendedGamepad?.rightThumbstick ?? profile?.dpads[GCInputRightThumbstick]
        case .unbound:
            return nil
        }
    }
    
    func rawStick(_ stick: PhysicalStick) -> SIMD2<Float>? {
        guard let element = stickElement(for: stick) else { return nil }
        
        return SIMD2(element.xAxis.value, element.yAxis.value)
    }
    
    
    func beginMenuNavigation(_ onInput: @escaping (MenuInput) -> Void) {
        menuHandler = onInput
        
        applyMapping(activeMapping)
    }
    
    func endMenuNavigation() {
        guard menuHandler != nil else { return }
        
        menuHandler = nil
        
        applyMapping(activeMapping)
    }
    
    private func installMenuHandlers(_ mapping: ControllerMapping) {
        for input in PhysicalInput.allCases where input != .unbound {
            let targets = mapping.emulatedButtons(for: input)
            
            guard !targets.isEmpty, let element = buttonElement(for: input) else { continue }
            
            let threshold = mapping.triggerThreshold
            
            element.valueChangedHandler = { [weak self] _, value, pressed in
                guard let self else { return }
                
                let isDown = input.isTrigger ? value >= threshold : pressed
                
                guard isDown else { return }
                
                for target in targets {
                    self.reportMenu(.button(target))
                }
            }
        }
        
        var feeds: [PhysicalStick: [(stick: ThumbstickType, config: StickMapping)]] = [:]
        
        for (stick, config) in [(ThumbstickType.left, mapping.leftStick), (.right, mapping.rightStick)] {
            guard config.source != .unbound else { continue }
            
            feeds[config.source, default: []].append((stick, config))
        }
        
        for (source, targets) in feeds {
            guard let element = stickElement(for: source) else { continue }
            
            element.valueChangedHandler = { [weak self] _, xValue, yValue in
                guard let self else { return }
                
                for target in targets {
                    let value = target.config.apply(x: xValue, y: yValue)
                    
                    self.reportMenu(.stick(target.stick, SIMD2(value.x, value.y)))
                }
            }
        }
    }
    
    private func reportMenu(_ input: MenuInput) {
        guard let handler = menuHandler else { return }
        
        DispatchQueue.main.async {
            handler(input)
        }
    }
    
    
    func beginCapture(_ onCapture: @escaping (CapturedInput) -> Void) {
        captureHandler = onCapture
        
        nativeController?.handlerQueue = inputQueue
        
        clearInputHandlers()
        
        for input in PhysicalInput.allCases where input != .unbound {
            guard let element = buttonElement(for: input) else { continue }
            
            element.valueChangedHandler = { [weak self] _, value, pressed in
                guard let self else { return }
                
                
                let actuated = input.isTrigger ? value >= 0.5 : pressed
                
                guard actuated else { return }
                
                self.report(.button(input))
            }
        }
        
        for stick in [PhysicalStick.left, .right] {
            guard let element = stickElement(for: stick) else { continue }
            
            element.valueChangedHandler = { [weak self] _, xValue, yValue in
                guard let self else { return }
                
                guard (xValue * xValue + yValue * yValue).squareRoot() >= 0.7 else { return }
                
                self.report(.stick(stick))
            }
        }
    }
    
    
    func endCapture() {
        captureHandler = nil
        
        applyMapping(activeMapping)
    }
    
    private func report(_ input: CapturedInput) {
        guard let handler = captureHandler else { return }
        
        captureHandler = nil
        
        DispatchQueue.main.async {
            handler(input)
        }
    }
    
    override func cleanup() {
        captureHandler = nil
        menuHandler = nil
        
        clearInputHandlers()
        
        super.cleanup()
    }
    
    private func clearInputHandlers() {
        guard let profile else { return }
        
        for button in profile.buttons.values {
            button.valueChangedHandler = nil
        }
        
        for dpad in profile.dpads.values {
            dpad.valueChangedHandler = nil
            dpad.up.valueChangedHandler = nil
            dpad.down.valueChangedHandler = nil
            dpad.left.valueChangedHandler = nil
            dpad.right.valueChangedHandler = nil
        }
    }
}
