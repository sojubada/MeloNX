//
//  StickPreview.swift
//  MeloNX
//
//  Created by Stossy11 on 29/9/2026.
//

import SwiftUI
import UIKit
import simd

struct StickPreview: View {
    let title: String
    @ObservedObject var visualizer: StickVisualizer
    let mapping: StickMapping
    
    private let size: CGFloat = 108
    private let dotSize: CGFloat = 14
    
    private var radius: CGFloat { (size - dotSize) / 2 }
    
    private var isBound: Bool { mapping.source != .unbound }
    
    private var raw: SIMD2<Float> { visualizer.value(for: mapping.source) }
    
    private var shaped: SIMD2<Float> {
        guard isBound else { return SIMD2<Float>() }
        
        let value = mapping.apply(x: raw.x, y: raw.y)
        
        return SIMD2(value.x, value.y)
    }
    
    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            
            ZStack {
                Circle()
                    .fill(Color(.secondarySystemBackground))
                
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                
                crosshair
                
                Circle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: deadzoneDiameter, height: deadzoneDiameter)
                
                if isBound {
                    trace
                    
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                        .frame(width: dotSize, height: dotSize)
                        .position(position(for: raw))
                    
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: dotSize, height: dotSize)
                        .position(position(for: shaped))
                }
            }
            .frame(width: size, height: size)
            
            Text(isBound
                 ? String(format: "%+.2f, %+.2f", shaped.x, shaped.y)
                 : String(localized: "Unbound"))
            .font(.caption2.monospacedDigit())
            .foregroundColor(.secondary)
        }
        .opacity(isBound ? 1 : 0.5)
        .accessibilityElement(children: .combine)
    }
    
    private var crosshair: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size / 2))
            path.addLine(to: CGPoint(x: size, y: size / 2))
            path.move(to: CGPoint(x: size / 2, y: 0))
            path.addLine(to: CGPoint(x: size / 2, y: size))
        }
        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
    }
    
    private var trace: some View {
        Path { path in
            path.move(to: CGPoint(x: size / 2, y: size / 2))
            path.addLine(to: position(for: shaped))
        }
        .stroke(Color.accentColor.opacity(0.4), lineWidth: 2)
    }
    
    private var deadzoneDiameter: CGFloat {
        CGFloat(mapping.deadzone) * radius * 2
    }
    
    private func position(for value: SIMD2<Float>) -> CGPoint {
        var x = CGFloat(value.x) * radius
        var y = CGFloat(value.y) * radius
        
        let length = (x * x + y * y).squareRoot()
        
        if length > radius {
            let multiplier = radius / length
            
            x *= multiplier
            y *= multiplier
        }
        
        return CGPoint(x: size / 2 + x, y: size / 2 - y)
    }
}
