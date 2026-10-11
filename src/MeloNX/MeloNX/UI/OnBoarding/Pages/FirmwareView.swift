//
//  FirmwareView.swift
//  MeloNX
//
//  Created by Stossy11 on 6/7/2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct FirmwareView: View {
    var goForward: () -> Void
    
    var fileImporter: FileImporterManager = .shared
    @ObservedObject var ryujinxController: RyujinxController = .shared
    let fileManager: FileManager = .default
    
    @State var fwAdded: Bool = false
    
    private var isInstalling: Bool {
        ryujinxController.firmwareInstallState.isInstalling
    }
    
    private var failureMessage: String? {
        if case .failed(let message) = ryujinxController.firmwareInstallState { return message }
        return nil
    }
    
    private var supportedSources: String {
        AppEnvironment.shared.needsAsCopy ? "Zip or XCI" : "Zip, Folder or XCI"
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .center) {
                Spacer()
                    .frame(height: 110)
                
                icon
                
                Text("Import Firmware")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .padding()
                
                if fwAdded {
                    Text("Firmware \(ryujinxController.firmwareVersion) is installed.\nYou can replace it at any time from the games list.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    Text("Import Firmware via \(supportedSources).\nRequired to be dumped from a Modded Nintendo Switch.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                
                if let failureMessage {
                    Text(failureMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
                
                if isInstalling {
                    VStack(spacing: 12) {
                        ProgressView()
                        
                        Text("Installing firmware...")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    ContinueButton(
                        text: buttonTitle,
                        action: importFirmware,
                        success: fwAdded,
                        enabled: .constant(true),
                        showCheckmark: false
                    )
                    .padding()
                }
            }
            .animation(.default, value: ryujinxController.firmwareInstallState)
        }
        .padding()
        .onAppear(perform: checkForFirmware)
        .onChange(of: ryujinxController.firmwareInstallState) { _ in
            checkForFirmware()
        }
        .ignoresSafeArea()
        .safeAreaInset(edge: .bottom, alignment: .center, spacing: 0) {
            Color.clear
                .frame(height: 80)
                .ignoresSafeArea()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.thinMaterial)
                        .ignoresSafeArea()
                        .frame(width: .infinity, height: .infinity)
                )
                .overlay(alignment: .bottom) {
                    ContinueButton(text: "Finish!", action: goForward, enabled: .constant(fwAdded && !isInstalling))
                        .if(UIDevice.current.userInterfaceIdiom == .pad) { view in
                            view
                                .padding(.bottom)
                        }
                }
        }
    }
    
    private var buttonTitle: LocalizedStringKey {
        if failureMessage != nil { return "Try Again" }
        return fwAdded ? "Replace Firmware" : "Import"
    }
    
    private var iconName: String {
        if fwAdded { return "checkmark.circle" }
        return failureMessage == nil ? "folder.circle" : "exclamationmark.circle"
    }
    
    private var iconColors: [Color] {
        if fwAdded { return [.green.opacity(0.6), .blue.opacity(0.6)] }
        if failureMessage != nil { return [.orange.opacity(0.6), .red.opacity(0.6)] }
        return [.blue.opacity(0.6), .red.opacity(0.6)]
    }
    
    private var icon: some View {
        Image(systemName: iconName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 120))
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 120)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: iconColors),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .shadow(color: .black.opacity(0.1), radius: 15, x: 0, y: 6)
    }
    
    func importFirmware() {
        guard !isInstalling else { return }
        
        fileImporter.importFiles(types: [.folder, .zip, .xci], allowMultiple: false, securityScoped: false) { result in
            ryujinxController.handleFirmwareImport(result: result)
        }
    }
    
    func checkForFirmware() {
        fwAdded = ryujinxController.firmwareInstalled
    }
}
