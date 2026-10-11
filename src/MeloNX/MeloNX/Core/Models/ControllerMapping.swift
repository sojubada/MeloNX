//
//  ControllerMapping.swift
//  MeloNX
//
//  Created by Stossy11 on 29/9/2026.
//

import Foundation
import GameController
import Melo_Controller

enum PhysicalInput: String, Codable, CaseIterable, Identifiable, Hashable {
    case unbound
    
    case a, b, x, y
    
    case dpadUp, dpadDown, dpadLeft, dpadRight
    
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger
    
    case leftStickButton, rightStickButton
    
    case menu, options, home
    
    var id: String { rawValue }
    
    static var assignable: [PhysicalInput] {
        allCases.filter { $0 != .unbound } + [.unbound]
    }
    
    var displayName: String {
        switch self {
        case .unbound: return String(localized: "Unbound")
        case .a: return String(localized: "A")
        case .b: return String(localized: "B")
        case .x: return String(localized: "X")
        case .y: return String(localized: "Y")
        case .dpadUp: return String(localized: "D-Pad Up")
        case .dpadDown: return String(localized: "D-Pad Down")
        case .dpadLeft: return String(localized: "D-Pad Left")
        case .dpadRight: return String(localized: "D-Pad Right")
        case .leftShoulder: return String(localized: "Left Shoulder")
        case .rightShoulder: return String(localized: "Right Shoulder")
        case .leftTrigger: return String(localized: "Left Trigger")
        case .rightTrigger: return String(localized: "Right Trigger")
        case .leftStickButton: return String(localized: "Left Stick Button")
        case .rightStickButton: return String(localized: "Right Stick Button")
        case .menu: return String(localized: "Menu")
        case .options: return String(localized: "Options")
        case .home: return String(localized: "Home")
        }
    }
    
    var gcButtonName: String? {
        switch self {
        case .a: return GCInputButtonA
        case .b: return GCInputButtonB
        case .x: return GCInputButtonX
        case .y: return GCInputButtonY
        case .leftShoulder: return GCInputLeftShoulder
        case .rightShoulder: return GCInputRightShoulder
        case .leftTrigger: return GCInputLeftTrigger
        case .rightTrigger: return GCInputRightTrigger
        case .leftStickButton: return GCInputLeftThumbstickButton
        case .rightStickButton: return GCInputRightThumbstickButton
        case .menu: return GCInputButtonMenu
        case .options: return GCInputButtonOptions
        case .home: return GCInputButtonHome
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .unbound: return nil
        }
    }
    
    var isTrigger: Bool {
        self == .leftTrigger || self == .rightTrigger
    }
}

enum PhysicalStick: String, Codable, CaseIterable, Identifiable, Hashable {
    case left, right, unbound
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .left: return String(localized: "Left Stick")
        case .right: return String(localized: "Right Stick")
        case .unbound: return String(localized: "Unbound")
        }
    }
}

struct StickMapping: Codable, Hashable {
    var source: PhysicalStick
    var invertX: Bool = false
    var invertY: Bool = false
    var rotate90: Bool = false
    var deadzone: Float = 0.1
    var range: Float = 1.0
    
    func apply(x: Float, y: Float) -> (x: Float, y: Float) {
        var vx = x
        var vy = y
        
        let magnitude = (vx * vx + vy * vy).squareRoot()
        
        if magnitude <= deadzone || magnitude == 0 {
            return (0, 0)
        }
        
        let scaled = min((magnitude - deadzone) / (1 - deadzone), 1) / magnitude
        vx *= scaled
        vy *= scaled
        
        if invertX { vx = -vx }
        if invertY { vy = -vy }
        
        if rotate90 {
            let oldX = vx
            vx = vy
            vy = -oldX
        }
        
        return (vx * range, vy * range)
    }
}


struct ControllerMapping: Codable, Hashable {
    var buttons: [String: PhysicalInput]
    var leftStick: StickMapping
    var rightStick: StickMapping
    
    var triggerThreshold: Float
    
    var motionEnabled: Bool
    
    init(buttons: [String: PhysicalInput],
        leftStick: StickMapping,
        rightStick: StickMapping,
        triggerThreshold: Float = 0.1,
        motionEnabled: Bool = true) {
        self.buttons = buttons
        self.leftStick = leftStick
        self.rightStick = rightStick
        self.triggerThreshold = triggerThreshold
        self.motionEnabled = motionEnabled
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = ControllerMapping.standard()
        
        buttons = try container.decodeIfPresent([String: PhysicalInput].self, forKey: .buttons) ?? standard.buttons
        leftStick = try container.decodeIfPresent(StickMapping.self, forKey: .leftStick) ?? standard.leftStick
        rightStick = try container.decodeIfPresent(StickMapping.self, forKey: .rightStick) ?? standard.rightStick
        triggerThreshold = try container.decodeIfPresent(Float.self, forKey: .triggerThreshold) ?? standard.triggerThreshold
        motionEnabled = try container.decodeIfPresent(Bool.self, forKey: .motionEnabled) ?? standard.motionEnabled
    }
    
    subscript(button: VirtualControllerButton) -> PhysicalInput {
        get { buttons[button.id] ?? .unbound }
        set { buttons[button.id] = newValue }
    }
    
    
    static func standard() -> ControllerMapping {
        ControllerMapping(
            buttons: [
                VirtualControllerButton.A.id: .a,
                VirtualControllerButton.B.id: .b,
                VirtualControllerButton.X.id: .x,
                VirtualControllerButton.Y.id: .y,
                VirtualControllerButton.dPadUp.id: .dpadUp,
                VirtualControllerButton.dPadDown.id: .dpadDown,
                VirtualControllerButton.dPadLeft.id: .dpadLeft,
                VirtualControllerButton.dPadRight.id: .dpadRight,
                VirtualControllerButton.leftShoulder.id: .leftShoulder,
                VirtualControllerButton.rightShoulder.id: .rightShoulder,
                VirtualControllerButton.leftTrigger.id: .leftTrigger,
                VirtualControllerButton.rightTrigger.id: .rightTrigger,
                VirtualControllerButton.leftStick.id: .leftStickButton,
                VirtualControllerButton.rightStick.id: .rightStickButton,
                VirtualControllerButton.start.id: .menu,
                VirtualControllerButton.back.id: .options,
                VirtualControllerButton.guide.id: .home,
            ],
            leftStick: StickMapping(source: .left),
            rightStick: StickMapping(source: .right)
        )
    }
    
    func emulatedButtons(for input: PhysicalInput) -> [VirtualControllerButton] {
        guard input != .unbound else { return [] }
        
        return buttons
            .filter { $0.value == input }
            .compactMap { VirtualControllerButton.bindable(id: $0.key) }
    }
}

extension VirtualControllerButton {
    static let bindableLeft: [VirtualControllerButton] = [
        .dPadUp, .dPadDown, .dPadLeft, .dPadRight, .back, .leftShoulder, .leftTrigger,
    ]
    
    static let bindableRight: [VirtualControllerButton] = [
        .A, .B, .X, .Y, .start, .rightShoulder, .rightTrigger, .guide,
    ]
    
    static var bindable: [VirtualControllerButton] {
        bindableLeft + bindableRight + [.leftStick, .rightStick]
    }
    
    static func bindable(id: String) -> VirtualControllerButton? {
        bindable.first { $0.id == id }
    }
    
    var switchDisplayName: String {
        switch id {
        case VirtualControllerButton.A.id: return String(localized: "A")
        case VirtualControllerButton.B.id: return String(localized: "B")
        case VirtualControllerButton.X.id: return String(localized: "X")
        case VirtualControllerButton.Y.id: return String(localized: "Y")
        case VirtualControllerButton.back.id: return String(localized: "Minus")
        case VirtualControllerButton.start.id: return String(localized: "Plus")
        case VirtualControllerButton.guide.id: return String(localized: "Home")
        case VirtualControllerButton.leftStick.id: return String(localized: "Stick Button")
        case VirtualControllerButton.rightStick.id: return String(localized: "Stick Button")
        case VirtualControllerButton.leftShoulder.id: return String(localized: "L")
        case VirtualControllerButton.rightShoulder.id: return String(localized: "R")
        case VirtualControllerButton.leftTrigger.id: return String(localized: "ZL")
        case VirtualControllerButton.rightTrigger.id: return String(localized: "ZR")
        case VirtualControllerButton.dPadUp.id: return String(localized: "D-Pad Up")
        case VirtualControllerButton.dPadDown.id: return String(localized: "D-Pad Down")
        case VirtualControllerButton.dPadLeft.id: return String(localized: "D-Pad Left")
        case VirtualControllerButton.dPadRight.id: return String(localized: "D-Pad Right")
        default: return id
        }
    }
}
