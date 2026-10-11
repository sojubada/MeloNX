//
//  EmulationView.swift
//  MeloNX
//
//  Created by Stossy11 on 23/4/2026.
//

import SwiftUI
import Melo_Controller
import Combine

struct EmulationView: View {
    var game: GameInfo
    @EnvironmentObject var ryujinxController: RyujinxController
    @ObservedObject var menuViewHandler: InGameConfigView_MenuView = .shared
    @StateObject var controllerManager: ControllerManager = .shared
    @StateObject var statisticsHandler: StatisticsHandler = .init()
    @StateObject private var nativeSettingsManager: NativeSettingsManager = .shared
    private var air = Air.shared
    
    @State var isConnected = false
    
    @ViewBuilder
    func emulationView(_ airplay: Bool = false) -> some View {
        if airplay { MetalViewRepresentable(showView: true).ignoresSafeArea().frame(maxWidth: .infinity, maxHeight: .infinity) } else {
            MetalViewContainer(showView: !isConnected, airplay: airplay, ryujinxController: ryujinxController, statisticsHandler: statisticsHandler, nativeSettingsManager: nativeSettingsManager)
                .overlay {
                    if controllerManager.hasVirtualController() && !airplay {
                        ControllerView(controller: VirtualControllerManager.shared, isEditing: false, gameId: game.titleId, gameName: game.titleName)
                            .opacity(nativeSettingsManager.setting(forKey: "On-ScreenControllerOpacity", default: 1.0).value)
                            .ignoresSafeArea(.all, edges: .vertical)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    var body: some View {
        Group {
            emulationView()
                .onAppear() {
                    statisticsHandler.registerPush()
                    
                    self.isConnected = Air.shared.connected
                    Air.shared.connectionCallbacks.append { self.isConnected = $0 }
                    
                    Air.play(AnyView(emulationView(true)))
                }
                .if(!statisticsHandler.started) { view in
                    view
                        .overlay {
                            LoadingOverlayView(game:  game, showLogs: false)
                                .onDisappear() {
                                    menuViewHandler.triggerButton()
                                }
                        }
                }
        }
    }
}
