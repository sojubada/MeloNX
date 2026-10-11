//
//  OpenInFiles.swift
//  MeloNX
//
//  Created by Stossy11 on 29/9/2026.
//

import UIKit

extension URL {
    @discardableResult
    func openInFiles() -> Bool {
        var shared = absoluteString
        
        if !ProcessInfo.processInfo.isiOSAppOnMac {
            shared = shared.replacingOccurrences(of: "file://", with: "shareddocuments://")
        }
        
        guard let url = URL(string: shared), UIApplication.shared.canOpenURL(url) else {
            return false
        }
        
        UIApplication.shared.open(url, options: [:])
        
        return true
    }
}

extension RyujinxController {
    func openSaveDirectory(for game: GameInfo, type: SaveDataType) {
        do {
            let path = try Ryujinx.saveDataPath(titleId: game.titleId, type: type)
            let url = URL(fileURLWithPath: path, isDirectory: true)
            
            guard url.openInFiles() else {
                AppAlerts.showSyncAlert(
                    title: "Couldn't Open Save Directory",
                    message: "The Files app couldn't open \(path).",
                    hasCancel: false
                )
                return
            }
        } catch SaveDataError.failedToResolve(let message) {
            AppAlerts.showSyncAlert(title: "Couldn't Open Save Directory", message: message, hasCancel: false)
        } catch {
            AppAlerts.showSyncAlert(title: "Couldn't Open Save Directory", message: error.localizedDescription, hasCancel: false)
        }
    }
}
