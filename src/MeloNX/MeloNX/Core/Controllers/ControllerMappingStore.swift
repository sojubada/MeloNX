//
//  ControllerMappingStore.swift
//  MeloNX
//
//  Created by Stossy11 on 29/9/2026.
//

import Foundation
import Combine
import GameController

final class ControllerMappingStore: ObservableObject {
    static let shared = ControllerMappingStore()
    
    @Published private(set) var mappings: [String: ControllerMapping] = [:]
    
    private let queue = DispatchQueue(label: "com.stossy11.melonx.controllermappings")
    
    private init() {
        mappings = Self.load()
    }
    
    func hasCustomMapping(for controller: BaseController) -> Bool {
        mappings[Self.key(for: controller)] != nil
    }
    
    func mapping(for controller: BaseController) -> ControllerMapping {
        mappings[Self.key(for: controller)] ?? .standard()
    }
    
    func setMapping(_ mapping: ControllerMapping, for controller: BaseController) {
        mappings[Self.key(for: controller)] = mapping
        persist()
    }
    
    func resetMapping(for controller: BaseController) {
        mappings.removeValue(forKey: Self.key(for: controller))
        persist()
    }
    
    static func key(for controller: BaseController) -> String {
        controller.virtual ? "virtual" : controller.name
    }
    
    private static func load() -> [String: ControllerMapping] {
        guard let data = try? Data(contentsOf: .controllerMappingsURL),
              let decoded = try? JSONDecoder().decode([String: ControllerMapping].self, from: data)
                else {
            return [:]
        }
        
        return decoded
    }
    
    private func persist() {
        let snapshot = mappings
        
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            
            try? data.write(to: .controllerMappingsURL, options: .atomic)
        }
    }
}

