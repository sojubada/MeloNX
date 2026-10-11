//
//  SteamControllerProtocol.swift
//  MeloNX
//
//  Created by Stossy11 on 02/10/2026.
//

import Foundation

nonisolated struct SteamControllerState {
    var buttons: UInt32 = 0
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    var stick = SIMD2<Float>(repeating: 0)
    var rightStick = SIMD2<Float>(repeating: 0)
    var accelerometer: SIMD3<Float>?
    var gyroscope: SIMD3<Float>?
}

nonisolated struct SteamControllerDecoder {
    private var lastSensorTimestamp: UInt32?

    mutating func decode(_ data: Data, reportID: UInt8) -> SteamControllerState? {
        guard (reportID == 0x45 || reportID == 0x47), data.count == 45 else { return nil }
        let bytes = Array(data)
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
        
        func signed(_ at: Int) -> Float { Float(Int16(bitPattern: u16(at))) }
        
        func axis(_ at: Int) -> Float {
            let value = signed(at)
            return value / (value < 0 ? 32768 : 32767)
        }
        let buttons = u32(1)
        var state = SteamControllerState()
        
        state.buttons = buttons
        state.leftTrigger = max(0, axis(5))
        state.rightTrigger = max(0, axis(7))
        state.stick = SIMD2(axis(9), axis(11))
        state.rightStick = SIMD2(axis(13), axis(15))
        
        let timestamp = reportID == 0x45 ? u32(29) : UInt32(u16(31))
        
        if timestamp != lastSensorTimestamp {
            state.accelerometer = SIMD3(-signed(33), signed(35), signed(37)) / 16384
            state.gyroscope = SIMD3(signed(39), -signed(41), -signed(43)) * (2000 / 32768)
            lastSensorTimestamp = timestamp
        }
        return state
    }
}

nonisolated enum SteamControllerProtocol {
    static func setting(_ number: UInt8, value: UInt16) -> Data {
        var bytes: [UInt8] = [0x87, 3, number, UInt8(truncatingIfNeeded: value), UInt8(value >> 8)]
        bytes += [UInt8](repeating: 0, count: 63 - bytes.count)
        return Data(bytes)
    }
    
    static var disableLizardMode: Data { setting(9, value: 0) }
    
    static func rumble(left: Float, right: Float) -> Data {
        func speed(_ value: Float) -> UInt16 {
            value.isFinite ? UInt16(min(1, max(0, value)) * 65535) : 0
        }
        let left = speed(left), right = speed(right)
        return Data([0, 0, 0, UInt8(truncatingIfNeeded: left), UInt8(left >> 8), 0,
                     UInt8(truncatingIfNeeded: right), UInt8(right >> 8), 0])
    }
}

