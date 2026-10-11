//
//  AirplayView.swift
//  MeloNX
//
//  Created by Stossy11 on 29/8/2026.
//

import SwiftUI

struct AirplayView: View {
    @EnvironmentObject var ryujinxController: RyujinxController
    @StateObject public var nativeSettingsManager = NativeSettingsManager.shared
    
    
    @State var selectedIndex: Int = 0
    
    @State var spinTrigger: Int = 0
    @State var spinReset: Bool = false
    
    var body: some View {
        Group {
            switch nativeSettingsManager.airplayCard(CardType.carousel).value {
            case .carousel:
                carousel
            case .list:
                GameRowsView(games: ryujinxController.games) { game in
                    ryujinxController.startGame(game)
                }
                .modifier(HiddenScrollBackground())
                .themedBackground()
            case let cardType:
                GameGridView(games: ryujinxController.games, cardType: cardType) { game in
                    ryujinxController.startGame(game)
                }
                .modifier(HiddenScrollBackground())
                .themedBackground()
            }
        }
    }
    
    private var carousel: some View {
        let cartridges: [CartridgeData] = ryujinxController.games.compactMap({ CartridgeData(labelImage: $0.icon ?? UIImage(), colors: [UIColor(hex: "171717"), .yellow]) })
        
        return CartridgeCarouselView(cartridges: cartridges, selectedIndex: $selectedIndex, uiMenu: { _ in UIMenu() }, spinTrigger: $spinTrigger, reset: $spinReset, spun: { index in
            let game = ryujinxController.games[index]
            DispatchQueue.main.async {
                ryujinxController.startGame(game)
            }
        })
        .menuNavigation { event in
            navigateCarousel(event)
        }
        .modifier(HiddenScrollBackground())
        .themedBackground()
        .ignoresSafeArea(.all)
    }
    
    
    private func navigateCarousel(_ event: MenuNavigation) {
        guard !ryujinxController.games.isEmpty else { return }
        
        switch event {
        case .left:
            selectedIndex = max(0, selectedIndex - 1)
            
        case .right:
            selectedIndex = min(ryujinxController.games.count - 1, selectedIndex + 1)
            
        case .confirm:
            spinTrigger += 1
            
        case .up, .down, .cancel:
            break
        }
    }
}
