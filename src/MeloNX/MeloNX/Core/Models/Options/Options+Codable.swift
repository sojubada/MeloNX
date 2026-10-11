//
//  Options+Codable.swift
//  MeloNX
//
//  Created by Stossy11 on 20/4/2026.
//

import UIKit
import Foundation

extension Options: Codable {
    enum CodingKeys: String, CodingKey {
        case controllerType1, controllerType2, controllerType3, controllerType4
        case controllerType5, controllerType6, controllerType7, controllerType8
        case hideCursorMode, listInputProfiles, listInputIds
        case disablePTC, enableInternetAccess, disableFsIntegrityChecks, fsGlobalAccessLogMode
        case disableVSync, vSyncMode, customVSyncInterval, disableShaderCache, enableTextureRecompression, disableDockedMode
        case systemLanguage, systemRegion, systemTimeZone, systemTimeOffset
        case memoryManagerMode, audioVolume, useHypervisor, ldnMitm, multiplayerLanInterfaceId
        case disableFileLog, loggingEnableDebug, loggingDisableStub, loggingDisableInfo
        case loggingDisableWarning, loggingEnableError, loggingEnableTrace, loggingDisableGuest
        case loggingEnableFsAccessLog, loggingGraphicsDebugLevel
        case resScale, maxAnisotropy, aspectRatio, backendThreading, enableAsyncShaderCompilation, disableMacroHLE
        case graphicsShadersDumpPath, graphicsBackend, preferredGPUVendor
        case antiAliasing, scalingFilter, scalingFilterLevel, metalFxUpscaleFactor
        case enableHostMemoryBudgetTracking
        case expandRAM, ignoreMissingServices
        case inputPath
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        
        try c.encodeIfPresent(graphicsShadersDumpPath, forKey: .graphicsShadersDumpPath)
        
        try c.encode(controllerType1.rawValue,   forKey: .controllerType1)
        try c.encode(controllerType2.rawValue,   forKey: .controllerType2)
        try c.encode(controllerType3.rawValue,   forKey: .controllerType3)
        try c.encode(controllerType4.rawValue,   forKey: .controllerType4)
        try c.encode(controllerType5.rawValue,   forKey: .controllerType5)
        try c.encode(controllerType6.rawValue,   forKey: .controllerType6)
        try c.encode(controllerType7.rawValue,   forKey: .controllerType7)
        try c.encode(controllerType8.rawValue,   forKey: .controllerType8)
        try c.encode(hideCursorMode.rawValue,    forKey: .hideCursorMode)
        try c.encode(listInputProfiles,          forKey: .listInputProfiles)
        try c.encode(listInputIds,               forKey: .listInputIds)
        try c.encode(disablePTC,                 forKey: .disablePTC)
        try c.encode(enableInternetAccess,       forKey: .enableInternetAccess)
        try c.encode(disableFsIntegrityChecks,   forKey: .disableFsIntegrityChecks)
        try c.encode(fsGlobalAccessLogMode,      forKey: .fsGlobalAccessLogMode)
        try c.encode(disableVSync,               forKey: .disableVSync)
        try c.encode(vSyncMode.rawValue,         forKey: .vSyncMode)
        try c.encode(customVSyncInterval,        forKey: .customVSyncInterval)
        try c.encode(disableShaderCache,         forKey: .disableShaderCache)
        try c.encode(enableTextureRecompression, forKey: .enableTextureRecompression)
        try c.encode(disableDockedMode,          forKey: .disableDockedMode)
        try c.encode(systemLanguage.rawValue,    forKey: .systemLanguage)
        try c.encode(systemRegion.rawValue,      forKey: .systemRegion)
        try c.encode(systemTimeZone,             forKey: .systemTimeZone)
        try c.encode(systemTimeOffset,           forKey: .systemTimeOffset)
        try c.encode(memoryManagerMode.rawValue, forKey: .memoryManagerMode)
        try c.encode(audioVolume,                forKey: .audioVolume)
        try c.encode(useHypervisor,              forKey: .useHypervisor)
        try c.encode(ldnMitm,                    forKey: .ldnMitm)
        try c.encode(multiplayerLanInterfaceId,  forKey: .multiplayerLanInterfaceId)
        try c.encode(disableFileLog,             forKey: .disableFileLog)
        try c.encode(loggingEnableDebug,         forKey: .loggingEnableDebug)
        try c.encode(loggingDisableStub,         forKey: .loggingDisableStub)
        try c.encode(loggingDisableInfo,         forKey: .loggingDisableInfo)
        try c.encode(loggingDisableWarning,      forKey: .loggingDisableWarning)
        try c.encode(loggingEnableError,         forKey: .loggingEnableError)
        try c.encode(loggingEnableTrace,         forKey: .loggingEnableTrace)
        try c.encode(loggingDisableGuest,        forKey: .loggingDisableGuest)
        try c.encode(loggingEnableFsAccessLog,   forKey: .loggingEnableFsAccessLog)
        try c.encode(loggingGraphicsDebugLevel.rawValue, forKey: .loggingGraphicsDebugLevel)
        try c.encode(resScale,                   forKey: .resScale)
        try c.encode(maxAnisotropy,              forKey: .maxAnisotropy)
        try c.encode(aspectRatio.rawValue,       forKey: .aspectRatio)
        try c.encode(backendThreading.rawValue,  forKey: .backendThreading)
        try c.encode(enableAsyncShaderCompilation, forKey: .enableAsyncShaderCompilation)
        try c.encode(disableMacroHLE,            forKey: .disableMacroHLE)
        try c.encode(graphicsBackend.rawValue,   forKey: .graphicsBackend)
        try c.encode(preferredGPUVendor,         forKey: .preferredGPUVendor)
        try c.encode(antiAliasing.rawValue,      forKey: .antiAliasing)
        try c.encode(scalingFilter.rawValue,     forKey: .scalingFilter)
        try c.encode(scalingFilterLevel,         forKey: .scalingFilterLevel)
        try c.encode(metalFxUpscaleFactor,        forKey: .metalFxUpscaleFactor)
        try c.encode(enableHostMemoryBudgetTracking, forKey: .enableHostMemoryBudgetTracking)
        try c.encode(expandRAM,                  forKey: .expandRAM)
        try c.encode(ignoreMissingServices,      forKey: .ignoreMissingServices)
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        
        func decodeCase<T>(
            _ type: T.Type,
            forKey key: CodingKeys,
            default defaultValue: T
        ) throws -> T where T: CaseIterable & RawRepresentable, T.RawValue: Decodable & Equatable {
            let rawValue = try c.decodeIfPresent(T.RawValue.self, forKey: key) ?? defaultValue.rawValue
            return T.allCases.first(where: { $0.rawValue == rawValue }) ?? defaultValue
        }
        
        inputPath = ""
        
        
        listInputProfiles          = try c.decodeIfPresent(Bool.self,   forKey: .listInputProfiles)        ?? false
        listInputIds               = try c.decodeIfPresent(Bool.self,   forKey: .listInputIds)             ?? false
        disablePTC                 = try c.decodeIfPresent(Bool.self,   forKey: .disablePTC)               ?? false
        enableInternetAccess       = try c.decodeIfPresent(Bool.self,   forKey: .enableInternetAccess)     ?? false
        disableFsIntegrityChecks   = try c.decodeIfPresent(Bool.self,   forKey: .disableFsIntegrityChecks) ?? false
        fsGlobalAccessLogMode      = try c.decodeIfPresent(Int32.self,  forKey: .fsGlobalAccessLogMode)    ?? 0
        disableVSync               = try c.decodeIfPresent(Bool.self,   forKey: .disableVSync)             ?? false
        vSyncMode                  = VSyncMode(rawValue: try c.decodeIfPresent(Int32.self, forKey: .vSyncMode) ?? (disableVSync ? VSyncMode.unbounded.rawValue : VSyncMode.switchMode.rawValue)) ?? .switchMode
        customVSyncInterval        = try c.decodeIfPresent(Int32.self,  forKey: .customVSyncInterval)      ?? 120
        disableShaderCache         = try c.decodeIfPresent(Bool.self,   forKey: .disableShaderCache)       ?? true
        enableTextureRecompression = try c.decodeIfPresent(Bool.self,   forKey: .enableTextureRecompression) ?? true
        disableDockedMode          = try c.decodeIfPresent(Bool.self,   forKey: .disableDockedMode)        ?? true
        systemTimeZone             = try c.decodeIfPresent(String.self, forKey: .systemTimeZone)           ?? "UTC"
        systemTimeOffset           = try c.decodeIfPresent(Int64.self,  forKey: .systemTimeOffset)         ?? 0
        audioVolume                = try c.decodeIfPresent(Float.self,  forKey: .audioVolume)              ?? 1.0
        useHypervisor              = try c.decodeIfPresent(Bool.self,   forKey: .useHypervisor)            ?? false
        ldnMitm                    = try c.decodeIfPresent(Bool.self,   forKey: .ldnMitm)                  ?? false
        multiplayerLanInterfaceId  = try c.decodeIfPresent(String.self, forKey: .multiplayerLanInterfaceId) ?? "0"
        disableFileLog             = try c.decodeIfPresent(Bool.self,   forKey: .disableFileLog)           ?? false
        loggingEnableDebug         = try c.decodeIfPresent(Bool.self,   forKey: .loggingEnableDebug)       ?? false
        loggingDisableStub         = try c.decodeIfPresent(Bool.self,   forKey: .loggingDisableStub)       ?? false
        loggingDisableInfo         = try c.decodeIfPresent(Bool.self,   forKey: .loggingDisableInfo)       ?? false
        loggingDisableWarning      = try c.decodeIfPresent(Bool.self,   forKey: .loggingDisableWarning)    ?? false
        loggingEnableError         = try c.decodeIfPresent(Bool.self,   forKey: .loggingEnableError)       ?? false
        loggingEnableTrace         = try c.decodeIfPresent(Bool.self,   forKey: .loggingEnableTrace)       ?? false
        loggingDisableGuest        = try c.decodeIfPresent(Bool.self,   forKey: .loggingDisableGuest)      ?? false
        loggingEnableFsAccessLog   = try c.decodeIfPresent(Bool.self,   forKey: .loggingEnableFsAccessLog) ?? false
        resScale                   = try c.decodeIfPresent(Float.self,  forKey: .resScale)                 ?? 1.0
        maxAnisotropy              = try c.decodeIfPresent(Float.self,  forKey: .maxAnisotropy)            ?? -1.0
        enableAsyncShaderCompilation = try c.decodeIfPresent(Bool.self, forKey: .enableAsyncShaderCompilation) ?? false
        disableMacroHLE            = try c.decodeIfPresent(Bool.self,   forKey: .disableMacroHLE)          ?? false
        preferredGPUVendor         = try c.decodeIfPresent(String.self, forKey: .preferredGPUVendor)       ?? ""
        scalingFilterLevel         = try c.decodeIfPresent(Int32.self,  forKey: .scalingFilterLevel)       ?? 60
        let decodedMetalFxFactor   = try c.decodeIfPresent(Float.self,  forKey: .metalFxUpscaleFactor)     ?? 2.0
        let clampedMetalFxFactor   = min(4.0, max(1.0, decodedMetalFxFactor))
        metalFxUpscaleFactor       = clampedMetalFxFactor > 3.0 ? 4.0 : (clampedMetalFxFactor * 10).rounded() / 10
        enableHostMemoryBudgetTracking = try c.decodeIfPresent(Bool.self, forKey: .enableHostMemoryBudgetTracking) ?? true
        expandRAM                  = try c.decodeIfPresent(Bool.self,   forKey: .expandRAM)                ?? false
        ignoreMissingServices      = try c.decodeIfPresent(Bool.self,   forKey: .ignoreMissingServices)    ?? false
        
        controllerType1        = try decodeCase(ControllerType.self, forKey: .controllerType1, default: .none)
        controllerType2        = try decodeCase(ControllerType.self, forKey: .controllerType2, default: .none)
        controllerType3        = try decodeCase(ControllerType.self, forKey: .controllerType3, default: .none)
        controllerType4        = try decodeCase(ControllerType.self, forKey: .controllerType4, default: .none)
        controllerType5        = try decodeCase(ControllerType.self, forKey: .controllerType5, default: .none)
        controllerType6        = try decodeCase(ControllerType.self, forKey: .controllerType6, default: .none)
        controllerType7        = try decodeCase(ControllerType.self, forKey: .controllerType7, default: .none)
        controllerType8        = try decodeCase(ControllerType.self, forKey: .controllerType8, default: .none)
        hideCursorMode         = try decodeCase(HideCursorMode.self, forKey: .hideCursorMode, default: .onIdle)
        systemLanguage         = try decodeCase(SystemLanguage.self, forKey: .systemLanguage, default: .americanEnglish)
        systemRegion           = try decodeCase(NativeRegionCode.self, forKey: .systemRegion, default: .USA)
        memoryManagerMode      = try decodeCase(MemoryManagerMode.self, forKey: .memoryManagerMode, default: .hostMappedUnsafe)
        loggingGraphicsDebugLevel = try decodeCase(GraphicsDebugLevel.self, forKey: .loggingGraphicsDebugLevel, default: .none)
        aspectRatio            = try decodeCase(AspectRatio.self, forKey: .aspectRatio, default: .fixed16x9)
        backendThreading       = try decodeCase(BackendThreading.self, forKey: .backendThreading, default: .off)
        graphicsBackend        = try decodeCase(GraphicsBackend.self, forKey: .graphicsBackend, default: .vulkan)
        antiAliasing           = try decodeCase(AntiAliasing.self, forKey: .antiAliasing, default: .none)
        scalingFilter          = try decodeCase(ScalingFilter.self, forKey: .scalingFilter, default: .bilinear)
        
        graphicsShadersDumpPath = try c.decodeIfPresent(String.self, forKey: .graphicsShadersDumpPath)
    }
    
    static func loadFromJSON(at url: URL) throws -> Options {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Options.self, from: data)
    }
    
    func saveAsJSON(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
