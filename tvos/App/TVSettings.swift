//
//  TVSettings.swift
//  MeloNX tvOS
//
//  Emulator settings for the Apple TV, saved in UserDefaults.
//  Same options as the iOS settings screen (UI/Main/Settings/SettingsView.swift),
//  minus what tvOS cannot use (touch controls, on-screen pad, MetalFX, AirPlay,
//  device motion, hypervisor) and with defaults chosen for a 4 GB Apple TV.
//

import Foundation
import Combine

struct TVSettingsValues: Codable, Equatable {
    // Graphics
    var resScale: Float = 1.0
    var dockedMode = false                 // TV mode: renders at 1080p, heavier
    var aspectRatio: Int = AspectRatio.fixed16x9.id
    var vSyncSwitch = true                 // false = unbounded
    var antiAliasing: Int = AntiAliasing.none.id
    var scalingFilter: Int = ScalingFilter.bilinear.id
    var maxAnisotropy: Float = -1          // -1 = auto (game decides)
    var textureRecompression = true
    var shaderCache = true
    var asyncShaderCompilation = false
    var backendThreading: Int = BackendThreading.on.id
    var macroHLE = true

    // System
    var language: Int = SystemLanguage.korean.id
    var region: Int = NativeRegionCode.korea.id
    var memoryManager: Int = MemoryManagerMode.hostMappedUnsafe.id
    var audioVolume: Float = 1.0
    var ptc = true                         // profiled translation cache
    var internetAccess = false
    var expandRAM = false
    var ignoreMissingServices = false
    var hostMemoryBudget = true

    // Input
    var player1Type: Int = ControllerType.proController.id

    // Menu
    var menuMusic = true
    var menuMusicVolume: Float = 0.5

    // Logs
    var debugLogs = false
}

/// Case of a MeloNX option enum by its `id` (Int), as stored in the settings.
func pick<T: CaseIterable & Identifiable>(_ id: Int, _ fallback: T) -> T where T.ID == Int {
    T.allCases.first { $0.id == id } ?? fallback
}

final class TVSettings: ObservableObject {
    static let shared = TVSettings()

    private static let key = "tvSettings.v1"

    @Published var values: TVSettingsValues {
        didSet { if values != oldValue { save() } }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(TVSettingsValues.self, from: data) {
            values = decoded
        } else {
            values = TVSettingsValues()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func reset() { values = TVSettingsValues() }

    /// Fills the core options from the saved settings.
    func apply(to o: inout Options) {
        let v = values
        o.resScale = v.resScale
        o.disableDockedMode = !v.dockedMode
        o.aspectRatio = pick(v.aspectRatio, .fixed16x9)
        o.vSyncMode = v.vSyncSwitch ? .switchMode : .unbounded
        o.disableVSync = !v.vSyncSwitch
        o.antiAliasing = pick(v.antiAliasing, AntiAliasing.none)
        o.scalingFilter = pick(v.scalingFilter, .bilinear)
        o.maxAnisotropy = v.maxAnisotropy
        o.enableTextureRecompression = v.textureRecompression
        o.disableShaderCache = !v.shaderCache
        o.enableAsyncShaderCompilation = v.asyncShaderCompilation
        o.backendThreading = pick(v.backendThreading, .on)
        o.disableMacroHLE = !v.macroHLE

        o.systemLanguage = pick(v.language, .korean)
        o.systemRegion = pick(v.region, .korea)
        o.memoryManagerMode = pick(v.memoryManager, .hostMappedUnsafe)
        o.audioVolume = v.audioVolume
        o.disablePTC = !v.ptc
        o.enableInternetAccess = v.internetAccess
        o.expandRAM = v.expandRAM
        o.ignoreMissingServices = v.ignoreMissingServices
        o.enableHostMemoryBudgetTracking = v.hostMemoryBudget

        o.controllerType1 = pick(v.player1Type, .proController)

        o.loggingEnableError = true
        o.loggingEnableDebug = v.debugLogs
    }
}
