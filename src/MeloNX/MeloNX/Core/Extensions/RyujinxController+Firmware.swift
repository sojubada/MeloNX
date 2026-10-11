//
//  RyujinxController+Firmware.swift
//  MeloNX
//
//  Created by Stossy11 on 29/9/2026.
//

import Foundation
import UIKit

public enum FirmwareInstallState: Equatable {
    case idle
    case installing
    case installed(version: String)
    case failed(message: String)
    
    var isInstalling: Bool {
        self == .installing
    }
}

extension RyujinxController {
    static let firmwareFileExtensions: Set<String> = ["zip", "xci"]
    
    @MainActor
    public func handleFirmwareImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            Task { await installFirmware(from: url) }
        case .failure(let error):
            let error = error as NSError
            guard error.domain != "FileImporterManager" || error.code != 2 else { return }
            
            firmwareInstallState = .failed(message: error.localizedDescription)
            AppAlerts.showSyncAlert(title: "Installing Firmware Failed", message: error.localizedDescription, hasCancel: false)
        }
    }
    
    @MainActor
    public func installFirmware(from url: URL) async {
        guard !firmwareInstallState.isInstalling else { return }
        
        let accessing = url.startAccessingSecurityScopedResource()
        defer { accessing ? url.stopAccessingSecurityScopedResource() : () }
        
        guard await validateFirmwareSource(url) else { return }
        
        firmwareInstallState = .installing
        
        let path = url.path
        let error: Error? = await Task.detached(priority: .userInitiated) {
            do {
                try Ryujinx.installFirmware(at: path)
                return nil
            } catch {
                return error
            }
        }.value
        
        if let error {
            let message = Self.firmwareErrorMessage(for: error)
            firmwareInstallState = .failed(message: message)
            AppAlerts.showSyncAlert(title: "Installing Firmware Failed", message: message, hasCancel: false)
            return
        }
        
        firmwareInstallState = .installed(version: firmwareVersion)
    }
    
    @MainActor
    private func validateFirmwareSource(_ url: URL) async -> Bool {
        var isDirectory: ObjCBool = false
        
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            failFirmwareImport(with: "The selected item could not be found anymore. Try importing it again.")
            return false
        }
        
        if isDirectory.boolValue {
            guard !Self.containsFirmwareContent(at: url) else { return true }
            
            let answer = await AppAlerts.showAlert(
                title: "This May Not Be Firmware",
                message: "No NCA files were found in \"\(url.lastPathComponent)\".",
                actions: ["Import Anyway"]
            )
            
            return answer == "Import Anyway"
        }
        
        guard Self.firmwareFileExtensions.contains(url.pathExtension.lowercased()) else {
            let supported = AppEnvironment.shared.needsAsCopy ? "a Zip or XCI file" : "a Zip file, XCI file or folder"
            failFirmwareImport(with: "\"\(url.lastPathComponent)\" can't be used as firmware. Select \(supported) dumped from a modded Nintendo Switch.")
            return false
        }
        
        return true
    }
    
    @MainActor
    private func failFirmwareImport(with message: String) {
        firmwareInstallState = .failed(message: message)
        AppAlerts.showSyncAlert(title: "Installing Firmware Failed", message: message, hasCancel: false)
    }
    
    private static func containsFirmwareContent(at url: URL, depth: Int = 3) -> Bool {
        guard depth > 0,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return false }
        
        var subdirectories: [URL] = []
        
        for item in contents {
            // An NCA can be a file or, on a raw dump, a folder holding its parts.
            if item.pathExtension.lowercased() == "nca" { return true }
            
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                subdirectories.append(item)
            }
        }
        
        for subdirectory in subdirectories.prefix(8) where containsFirmwareContent(at: subdirectory, depth: depth - 1) {
            return true
        }
        
        return false
    }
    
    static func firmwareErrorMessage(for error: Error) -> String {
        var raw = error.localizedDescription
        
        if let installError = error as? FirmwareInstallationError,
           case .failedInstall(let string) = installError {
            raw = string
        }
        
        print("Firmware installation failed: \(raw)")
        
        if raw.contains("MissingKeyException") || raw.contains("InvalidKeyException") {
            return "The keys MeloNX has can't decrypt this firmware. Import a prod.keys that matches the firmware version, then try again."
        }
        
        if raw.contains("InvalidFirmwarePackageException") || raw.localizedCaseInsensitiveContains("invalid firmware") {
            return "This isn't a valid firmware dump. Use a Zip or XCI dumped from a modded Nintendo Switch."
        }
        
        if raw.contains("UnauthorizedAccessException") || raw.localizedCaseInsensitiveContains("permission denied") {
            return "MeloNX couldn't read the selected item. Copy it into the MeloNX folder and import it from there."
        }
        
        if raw.contains("FileNotFoundException") || raw.contains("DirectoryNotFoundException") {
            return "Part of the firmware couldn't be read. If it is stored in iCloud Drive, download it to this device first."
        }
        
        return firstMeaningfulLine(of: raw)
    }
    
    
    private static func firstMeaningfulLine(of raw: String) -> String {
        let lines = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        
        guard let line = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("at ") && !$0.hasPrefix("--- ") }) else {
            return raw
        }
        
        
        if let separator = line.range(of: ": "), line[line.startIndex..<separator.lowerBound].contains("Exception") {
            return String(line[separator.upperBound...])
        }
        
        return line
    }
}
