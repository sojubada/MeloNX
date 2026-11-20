//
//  TVShims.swift
//  MeloNX tvOS
//
//  Stand-ins for the few iOS-app types that the reused core files mention.
//  The tvOS target compiles Core/Ryujinx.swift, Core/Models/** and the native
//  controller files unchanged; these are the only outside names they touch.
//

import UIKit

/// iOS: Common/AirPlay/Air.swift drives an external AirPlay screen.
/// On Apple TV the TV *is* the screen, so there is never a second one.
final class Air {
    static let shared = Air()
    var airScreen: UIScreen? { nil }
}

/// iOS: UI/Emulation/Metal/MetalFxBridge.swift wires MetalFX spatial upscaling.
/// Not ported: it is an optional scaling filter and the tvOS build keeps bilinear.
enum MetalFxBridge {
    static var isSupported: Bool { false }
}
