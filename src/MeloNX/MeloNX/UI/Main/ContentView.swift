//
//  ContentView.swift
//  MeloNX
//
//  Created by Stossy11 on 4/4/2026.
//

import SwiftUI
import MetalKit
import Melo_Controller

struct EnvironmentVariable: Codable, Hashable {
    let string: String
    var value: String
    
    func set() {
        setenv(string, value, 1)
    }
    
    static func set(_ env: EnvironmentVariable) {
        setenv(env.string, env.value, 1)
    }
}



struct ContentView: View {
    @EnvironmentObject var ryujinxController: RyujinxController
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject public var nativeSettingsManager = NativeSettingsManager.shared
    @StateObject var controllerManager: ControllerManager = .shared
    @State private var selectedTab: Tab = .games
    @Environment(\.appTheme) var theme
    
    var tabView: some View {
        TabView(selection: $selectedTab) {
            GamesListView()
                .tabItem { Label("Library", systemImage: "gamecontroller.fill") }
                .tag(Tab.games)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(Tab.settings)
        }
        .accentColor(theme.accent.primary)
        .onAppear { NativeSettingsManager.setShared() }
        .task {
            ryujinxController.loadConfig()

            if ryujinxController.lastGameLaunched == nil {
                EnableJIT.enableJIT(nativeSettingsManager.jitProvider(JITProvider.disabled).value)
            }
            
            _ = ryujinxController.attemptToMapDualMapping()
            
            ryujinxController.loadGames()
            
            try? await Task.sleep(nanoseconds: 100_000_000)
            
            controllerManager.initAll()
            
            MetalViewRepresentable.createView()
            
            AlertHandlers.register()
            
            Air.play(AnyView(AirplayView().environmentObject(ryujinxController)))
            
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            if let gameId = ryujinxController.lastGameLaunched, let game = ryujinxController.games.first(where: { $0.titleId == gameId }) {
                ryujinxController.startGame(game)
            } else {
                ryujinxController.lastGameLaunched = nil
            }
        }
    }
    
    @ViewBuilder
    func emulationView(game: GameInfo, state: StartedState) -> some View {
        switch state {
        case .none:
            EmulationView(game: game)
        case .entitlement:
            ControllerView(controller: VirtualControllerManager.shared, isEditing: false)
                .allowsHitTesting(false)
                .frame(width: .infinity, height: .infinity)
                .alert(isPresented: .constant(ryujinxController.isRunning.isEntitlement())) {
                    Alert(
                        title: Text("Entitlement"),
                        message: Text(LocalizedStringKey("MeloNX **REQUIRES** the Increased Memory Limit entitlement, Please follow the instructions on how to Install MeloNX and Enable the Entitlement.")),
                        primaryButton: .default(Text("Instructions")) {
                            UIApplication.shared.open(
                                URL(string: "https://git.ryujinx.app/projects/MeloNX#how-to-install")!,
                                options: [:],
                                completionHandler: nil
                            )
                            ryujinxController.isRunning = .stopped
                        },
                        secondaryButton: .cancel(Text("Cancel")) {
                            ryujinxController.isRunning = .stopped
                        }
                    )
                }
        case .noJIT:
            NoJITView(game: game)
                .onAppear() {
                    Air.play(AnyView(NoJITView(game: game).environmentObject(ryujinxController)))
                }
                .onDisappear() {
                    if case .started(game: _, state: let state) = ryujinxController.isRunning {
                        switch state {
                        case .entitlement, .extendedEntitlement:
                            Air.play(AnyView(EmptyView()))
                        case .usersList:
                            Air.play(AnyView(EmptyView()))
                        default: break
                        }
                    } else {
                        Air.play(AnyView(AirplayView().environmentObject(ryujinxController)))
                    }
                }
        case .extendedEntitlement:
            ControllerView(controller: VirtualControllerManager.shared, isEditing: false)
                .allowsHitTesting(false)
                .frame(width: .infinity, height: .infinity)
                .alert(isPresented: .constant(ryujinxController.isRunning.isEntitlement())) {
                    Alert(
                        title: Text("Extended Virtual Addressing"),
                        message: Text(LocalizedStringKey("The Extended Virtual Addressing entitlement is required for your device, Please read the Information on how to Install MeloNX and Enable the **PAID** Entitlement.")),
                        primaryButton: .default(Text("Information")) {
                            UIApplication.shared.open(
                                URL(string: "https://git.ryujinx.app/projects/MeloNX#entitlements")!,
                                options: [:],
                                completionHandler: nil
                            )
                            ryujinxController.isRunning = .stopped
                        },
                        secondaryButton: .cancel(Text("Cancel")) {
                            ryujinxController.isRunning = .stopped
                        }
                    )
                }
        case .usersList:
            EmptyView() // TODO: Finish eventually™
        }
    }
    
    var body: some View {
        Group {
            switch ryujinxController.isRunning {
            case .stopped:
                tabView
            case .started(game: let game, state: let state):
                emulationView(game: game, state: state)
            case .crashed(result: let crashed):
                tabView
                    .alert(isPresented: .constant(ryujinxController.isRunning.hasCrashed())) {
                        Alert(
                            title: Text("MeloNX Crashed!"),
                            message: Text(LocalizedStringKey("MeloNX crashed with result: \(crashed)")),
                            dismissButton: .cancel(Text("Cancel")) {
                                ryujinxController.isRunning = .stopped
                            }
                        )
                    }
            }
        }

    }
}





#Preview {
    ContentView()
}
