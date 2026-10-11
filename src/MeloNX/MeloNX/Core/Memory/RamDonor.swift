//
//  RamDonor.swift
//  MeloNX
//
//  Created by Stossy11 on 29/9/2026.
//

import Foundation

enum RamDonor {
    private static let mib: UInt64 = 1024 * 1024
    
    static var isEnabled: Bool {
        get { NativeSettingsManager.shared.setting(forKey: "donateGuestMemory", default: true).value }
        set { NativeSettingsManager.shared.setting(forKey: "donateGuestMemory", default: true).value = newValue }
    }
    
    static var gpuBuffersEnabled: Bool {
        NativeSettingsManager.shared.setting(forKey: "donateGpuBuffers", default: false).value
    }
    
    static var killDonorsAfterMapping: Bool {
        get { NativeSettingsManager.shared.setting(forKey: "killDonorsAfterMapping", default: true).value }
        set { NativeSettingsManager.shared.setting(forKey: "killDonorsAfterMapping", default: true).value = newValue }
    }
    
    private(set) static var region: UnsafeMutableRawPointer?
    private(set) static var jitRegion: UnsafeMutableRawPointer?
    private(set) static var regionSize: UInt64 = 0
    private(set) static var jitRegionSize: UInt64 = 0
    private(set) static var lastStatus: String = "Not attempted yet"
    
    private static var nativeError: String? {
        guard let raw = mlx_ram_donor_last_error() else { return nil }
        
        let text = String(cString: raw)
        
        return text.isEmpty ? nil : text
    }
    
    private static func fail(_ reason: String) -> Bool {
        lastStatus = [reason, nativeError].compactMap { $0 }.joined(separator: ": ")
        print(lastStatus)
        
        return false
    }
    
    @discardableResult
    static func prepare(bytes: UInt64) -> Bool {
        guard bytes > 0 else {
            return fail("Asked for no memory, nothing to do")
        }
        
        guard isEnabled || gpuBuffersEnabled else {
            return fail("Memory donation is turned off in Settings")
        }
        
        guard isSupported else {
            return fail("The memory helper is missing from this build")
        }
        
        guard region == nil else {
            lastStatus = "Already holding \(regionSize / mib) MB"
            return true
        }
        
        let requestedGuest: UInt64 = isEnabled ? bytes : 0
        let requestedGpu: UInt64 = gpuBuffersEnabled ? 512 * mib : 0
        let requested = requestedGuest + requestedGpu
        
        mlx_ram_donor_set_kill_after_mapping(killDonorsAfterMapping)
        
        
        var granted: UInt64 = 0
        let minimum = min(requested, 256 * mib)
        
        guard let mapped = mlx_ram_donor_acquire_up_to(requested, minimum, &granted),
              granted > 0 else {
            let reason = nativeError ?? "No donor memory available"
            mlx_ram_donor_shutdown()
            return fail("Could not source donor memory: \(reason)")
        }
        
        
        let guestBytes = min(granted, requestedGuest)
        let gpuBytes = granted - guestBytes
        
        region = mapped
        regionSize = granted
        
        if guestBytes > 0 {
            offer_donated_memory(mapped, guestBytes)
        }
        
        var gpuStatus = "GPU buffers off"
        if gpuBytes > 0 {
            let gpuAddress = mapped.advanced(by: Int(guestBytes))
            if offer_donated_gpu_memory(gpuAddress, gpuBytes) != 0 {
                gpuStatus = "\(gpuBytes / mib) MiB offered for GPU buffers (driver import required)"
            } else {
                gpuStatus = "GPU buffer offer rejected"
            }
        } else if gpuBuffersEnabled {
            gpuStatus = "GPU buffers using normal memory (insufficient donor budget)"
        }
        
        let partial = granted < requested ? " (partial: donors could carry \(granted / mib) of \(requested / mib) MiB)" : ""
        lastStatus = "Guest RAM: \(guestBytes / mib) MiB; \(gpuStatus)\(partial)"
        print(lastStatus)
        
        return true
    }
    
    static func teardown() {
        guard region != nil else { return }
        
        
        guard withdraw_donated_gpu_memory() != 0 else {
            lastStatus = "Keeping donor memory alive: GPU buffers are still in use"
            print(lastStatus)
            return
        }
        
        withdraw_donated_memory()
        
        if let region {
            mlx_ram_donor_release(region)
        }
        
        mlx_ram_donor_shutdown()
        
        region = nil
        regionSize = 0
    }
    
    
    static var isSupported: Bool {
        mlx_ram_donor_is_available()
    }
}
