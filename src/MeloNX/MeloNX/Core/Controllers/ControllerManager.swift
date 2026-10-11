//
//  ControllerManager.swift
//  MeloNX
//
//  Created by Stossy11 on 19/10/2025.
//

import Foundation
import Combine
import GameController
import SwiftUI

class ControllerManager: ObservableObject {
    static var shared = ControllerManager()
    let virtualController = BaseController(nativeController: nil)
    @AppStorage("isVirtualController") var isVCA: Bool = true
    
    private let controllerQueue = DispatchQueue(label: "com.stossy11.melonx.controllermanager", attributes: .concurrent)
    
    private var _privAllControllers: [BaseController] = []
    @Published var allControllers: [BaseController] = []
    
    @Published var selectedControllers: [String] = [] 
    private var didInitControllerObservers = false
    
    @Published private(set) var hasPhysicalController = false
    
    private var menuListeners: [(id: UUID, handler: (MenuNavigation) -> Void)] = []
    private var menuNavigator: MenuNavigator?
    
    
    func initAll() {
        refreshControllersList()
        initControllerObservers()
        SteamControllerBackend.shared.start()
    }
    
    private init() {
        controllerQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self._privAllControllers.append(self.virtualController)
            let controllers = self._privAllControllers
            
            DispatchQueue.main.async {
                self.allControllers = controllers
            }
        }
    }
    
    
    func refreshControllersList(_ inGameSelector: Bool = false) {
        let nativeSettingsManager: NativeSettingsManager = .shared
        let connectedNativeControllers = GCController.controllers()
        let connectedSet = Set(connectedNativeControllers)
        let steamControllers = Thread.isMainThread ? SteamControllerBackend.shared.controllers : DispatchQueue.main.sync { SteamControllerBackend.shared.controllers }
        let previousSelection = selectedControllerIdsSnapshot()
        
        controllerQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            var controllersToRemove: [BaseController] = []
            for controller in self._privAllControllers where !controller.virtual {
                if let steam = controller as? SteamController {
                    if !steamControllers.contains(where: { $0 === steam }) {
                        controllersToRemove.append(controller)
                    }
                    continue
                }
                if let native = controller.nativeController, !connectedSet.contains(native) {
                    controllersToRemove.append(controller)
                }
            }
            
            for controller in controllersToRemove {
                controller.cleanup()
                self._privAllControllers.removeAll { $0 === controller }
            }
            
            for nativeController in connectedNativeControllers {
                if !self._privAllControllers.contains(where: { $0.nativeController === nativeController }) {
                    let newController = NativeController(nativeController: nativeController)
                    self._privAllControllers.append(newController)
                }
            }
            
            for controller in steamControllers where !self._privAllControllers.contains(where: { $0 === controller }) {
                self._privAllControllers.append(controller)
            }
            
            let virtualControllers = self._privAllControllers.filter { $0.virtual }
            let physical = self._privAllControllers
                .filter { !$0.virtual }
                .sorted { lhs, rhs in
                    let lhsIndex = connectedNativeControllers.firstIndex { $0 === lhs.nativeController } ?? (connectedNativeControllers.count + (steamControllers.firstIndex { $0 === lhs } ?? steamControllers.count))
                    
                    let rhsIndex = connectedNativeControllers.firstIndex { $0 === rhs.nativeController } ?? (connectedNativeControllers.count + (steamControllers.firstIndex { $0 === rhs } ?? steamControllers.count))
                    
                    return lhsIndex < rhsIndex
                }
            
            self._privAllControllers = virtualControllers + physical
            
            // Full Keyboard Support may come eventually, i'm just too lazy :3
            // _privAllControllers.append(KBController()) // This was just an experiment, yes it did work, no i'm not bothered to fully implement it.
            
            
            let physicalControllers = self._privAllControllers.prefix(7).filter { !$0.virtual }.compactMap(\.id) as [String]
            let controllers = Array(self._privAllControllers.prefix(7))
            
            let selectedControllerIds: [String]
            
            if inGameSelector {
                let known = Set(self._privAllControllers.map(\.id))
                selectedControllerIds = previousSelection.filter { known.contains($0) }
            } else if !nativeSettingsManager.virtualControllerOffDefault(ProcessInfo.processInfo.isiOSAppOnMac).value {
                selectedControllerIds = physicalControllers.isEmpty ? [self.virtualController.id] : physicalControllers
            } else {
                selectedControllerIds = physicalControllers
            }
            
            // RyujinxController.shared.isRunning.isRunning(
            
            DispatchQueue.main.async {
                self.allControllers = controllers
                self.selectedControllers = selectedControllerIds
                self.hasPhysicalController = controllers.contains { !$0.virtual }
                
                let isRunning = RyujinxController.shared.isRunning.isRunning()
                
                if isRunning {
                    self.attachAllControllers(selectedControllerIds: selectedControllerIds)
                }
            }
        }
    }
    
    func attachAllControllers() {
        attachAllControllers(selectedControllerIds: selectedControllerIdsSnapshot())
    }
    
    private func attachAllControllers(selectedControllerIds: [String]) {
        let config = RyujinxController.shared.settings
        
        controllerQueue.sync {
            for controller in _privAllControllers {
                Ryujinx.detachGamepad(controller.pointer)
            }
            
            var playerIndex = 0
            
            for controllerId in selectedControllerIds {
                guard let cont = _privAllControllers.first(where: { $0.id == controllerId }) else { continue }
                
                if cont.controllerType != config.controllerType(for: playerIndex) {
                    cont.controllerType ?= config.controllerType(for: playerIndex)
                }
                
                cont.attach(playerIndex, controllerType: cont.controllerType)
                
                playerIndex += 1
            }
        }
    }
    
    
    var resolvedSelection: [(id: String, controller: BaseController)] {
        selectedControllers.compactMap { id in
            guard let controller = allControllers.first(where: { $0.id == id }) else { return nil }
            
            return (id, controller)
        }
    }
    
    private func selectedControllerIdsSnapshot() -> [String] {
        if Thread.isMainThread {
            return selectedControllers
        }
        
        return DispatchQueue.main.sync {
            selectedControllers
        }
    }
    
    func controllerAndIndexForString(_ id: String) -> (BaseController, Int)? {
        return controllerQueue.sync {
            guard let controller = _privAllControllers.first(where: { $0.id == id }),
                  let index = _privAllControllers.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return (controller, index)
        }
    }
    
    func controllerForString(_ id: String) -> BaseController? {
        return controllerQueue.sync {
            return _privAllControllers.first(where: { $0.id == id })
        }
    }
    
    func firstControllerForName(_ name: String) -> BaseController? {
        return controllerQueue.sync {
            return _privAllControllers.first(where: { $0.nativeController?.vendorName ?? UUID().uuidString == name })
        }
    }
    
    func hasVirtualController() -> Bool {
        let selectedControllerIds = selectedControllerIdsSnapshot()
        
        return controllerQueue.sync {
            return selectedControllerIds.contains(_privAllControllers.first(where: { $0.virtual })?.id ?? "Failed to find virtual controller!")
        }
    }
    
    func initControllerObservers() {
        guard !didInitControllerObservers else { return }
        didInitControllerObservers = true
        
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
                self.refreshControllersList()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
                self.refreshControllersList()
            }
        }
    }
    
    @MainActor
    func beginMenuNavigation(_ id: UUID, handler: @escaping (MenuNavigation) -> Void) {
        if let index = menuListeners.firstIndex(where: { $0.id == id }) {
            menuListeners[index].handler = handler
        } else {
            menuListeners.append((id, handler))
        }
        
        syncMenuNavigation()
    }
    
    @MainActor
    func endMenuNavigation(_ id: UUID) {
        menuListeners.removeAll { $0.id == id }
        
        syncMenuNavigation()
    }
    
    @MainActor
    private func syncMenuNavigation() {
        guard !menuListeners.isEmpty else {
            menuNavigator?.stop()
            menuNavigator = nil
            
            return
        }
        
        let navigator = menuNavigator ?? MenuNavigator()
        
        menuNavigator = navigator
        
        navigator.start { [weak self] event in
            self?.menuListeners.last?.handler(event)
        }
    }
    
    func toggleController(_ baseController: BaseController) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let index = self.selectedControllers.firstIndex(where: { $0 == baseController.id }) {
                self.selectedControllers.remove(at: index)
            } else {
                self.selectedControllers.append(baseController.id)
            }
        }
    }
}
