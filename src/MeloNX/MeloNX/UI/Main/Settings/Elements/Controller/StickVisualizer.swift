//
//  StickVisualizer.swift
//  MeloNX
//
//  Created by Stossy11 on 29/9/2026.
//

import Foundation
import Combine
import QuartzCore
import simd

final class StickVisualizer: ObservableObject {
    @Published private(set) var left = SIMD2<Float>()
    @Published private(set) var right = SIMD2<Float>()
    
    private let deadband: Float = 0.004
    
    private weak var controller: NativeController?
    private var displayLink: CADisplayLink?
    
    init(controller: NativeController?) {
        self.controller = controller
    }
    
    deinit {
        displayLink?.invalidate()
    }
    
    func value(for source: PhysicalStick) -> SIMD2<Float> {
        switch source {
        case .left: return left
        case .right: return right
        case .unbound: return SIMD2<Float>()
        }
    }
    
    func start() {
        guard displayLink == nil, controller != nil else { return }
        
        let link = CADisplayLink(target: DisplayLinkProxy(target: self), selector: #selector(DisplayLinkProxy.tick))
        
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        
        displayLink = link
    }
    
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    fileprivate func tick() {
        guard let controller else { return }
        
        let polledLeft = controller.rawStick(.left) ?? SIMD2<Float>()
        let polledRight = controller.rawStick(.right) ?? SIMD2<Float>()
        
        if moved(polledLeft, from: left) { left = polledLeft }
        if moved(polledRight, from: right) { right = polledRight }
    }
    
    private func moved(_ polled: SIMD2<Float>, from published: SIMD2<Float>) -> Bool {
        if polled == published { return false }
        
        if polled == SIMD2<Float>() { return true }
        
        return abs(polled.x - published.x) >= deadband || abs(polled.y - published.y) >= deadband
    }
}

private final class DisplayLinkProxy: NSObject {
    private weak var target: StickVisualizer?

    init(target: StickVisualizer) {
        self.target = target
    }

    @objc func tick() {
        target?.tick()
    }
}
