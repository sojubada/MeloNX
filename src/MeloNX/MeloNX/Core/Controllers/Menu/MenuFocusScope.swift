//
//  MenuFocusScope.swift
//  MeloNX
//
//  Created by Stossy11 on 29/9/2026.
//

import SwiftUI
import Combine

struct MenuFocusFrame: Equatable {
    let id: AnyHashable
    let frame: CGRect
}

struct MenuFocusFramesKey: PreferenceKey {
    static var defaultValue: [MenuFocusFrame] = []

    static func reduce(value: inout [MenuFocusFrame], nextValue: () -> [MenuFocusFrame]) {
        value += nextValue()
    }
}

let menuFocusCoordinateSpace = "MenuFocusScope"


final class MenuFocusScope: ObservableObject {
    @Published private(set) var focusedID: AnyHashable?

    private var ids: [AnyHashable] = []
    
    private var frames: [AnyHashable: CGRect] = [:]

    func setItems(_ newIDs: [AnyHashable]) {
        ids = newIDs

        if let focusedID, !newIDs.contains(focusedID) {
            self.focusedID = nil
        }
    }

    func setFrames(_ measured: [MenuFocusFrame]) {
        frames = Dictionary(measured.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
    }

    func clearFocus() {
        focusedID = nil
    }

    @discardableResult
    func focusFirstIfNeeded() -> Bool {
        guard focusedID == nil else { return false }

        focusedID = ids.first

        return true
    }

    func move(_ direction: MenuNavigation) {
        guard !ids.isEmpty, !focusFirstIfNeeded() else { return }

        guard let focusedID, let index = ids.firstIndex(of: focusedID) else { return }

        let columns = columnsPerRow
        let step: Int

        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -columns
        case .down: step = columns
        case .confirm, .cancel: return
        }

        var target = index + step

        if target >= ids.count {
            guard direction == .down, index < ids.count - 1 else { return }

            target = ids.count - 1
        }

        guard target >= 0 else { return }

        self.focusedID = ids[target]
    }

    private var columnsPerRow: Int {
        guard frames.count > 1 else { return 1 }

        var perRow: [Int: Int] = [:]

        for frame in frames.values {
            perRow[Int(frame.minY.rounded()), default: 0] += 1
        }

        return max(1, perRow.values.max() ?? 1)
    }
}
