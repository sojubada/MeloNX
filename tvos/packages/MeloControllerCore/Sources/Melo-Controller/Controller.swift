//
//  Controller.swift
//  Melo-Controller (tvOS subset)
//
//  Copied from stossy11/Melo-Controller (GPL-3.0), Sources/Melo-Controller/Controller.swift.
//  Only the import changed: Combine is enough for ObservableObject.
//

import Combine
import CoreGraphics

public protocol Controller: ObservableObject {
    func buttonPressed(_ button: VirtualControllerButton)
    func buttonReleased(_ button: VirtualControllerButton)
    
    func joystickMoved(position: CGPoint, right: Bool)
}
