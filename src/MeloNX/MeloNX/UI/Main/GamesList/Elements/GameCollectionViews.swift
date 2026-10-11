//
//  GameCollectionViews.swift
//  MeloNX
//
//  Created by Stossy11 on 29/9/2026.
//

import SwiftUI

// Had to remove SwiftUI Grid, was kinda dreading this but it was surprisingly easy.
struct GameGridView<Menu: View>: View {
    let games: [GameInfo]
    let cardType: CardType
    
    var isActive: Bool = true
    
    let onSelect: (GameInfo) -> Void
    
    @ViewBuilder let menu: (GameInfo) -> Menu
    
    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVGrid(columns: cardType.gridColumns, spacing: 16) {
                    ForEach(games) { game in
                        GameCardView(game: game)
                            .contextMenu { menu(game) }
                    }
                }
                .padding(.horizontal)
                .padding(.top)
                .menuFocusScope(
                    items: games,
                    scrollProxy: proxy,
                    isActive: isActive,
                    onConfirm: onSelect
                )
            }
        }
    }
}

extension GameGridView where Menu == EmptyView {
    init(games: [GameInfo], cardType: CardType, isActive: Bool = true, onSelect: @escaping (GameInfo) -> Void) {
        self.init(games: games, cardType: cardType, isActive: isActive, onSelect: onSelect) { _ in EmptyView() }
    }
}

struct GameRowsView<Menu: View>: View {
    let games: [GameInfo]
    
    var isActive: Bool = true
    
    let onSelect: (GameInfo) -> Void
    
    @ViewBuilder let menu: (GameInfo) -> Menu
    
    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(spacing: 0) {
                    ForEach(games) { game in
                        GameRowView(game: game)
                            .padding(.horizontal)
                            .padding(.vertical, 5)
                            .contextMenu { menu(game) }
                    }
                }
                .menuFocusScope(
                    items: games,
                    scrollProxy: proxy,
                    isActive: isActive,
                    onConfirm: onSelect
                )
            }
        }
    }
}

extension GameRowsView where Menu == EmptyView {
    init(games: [GameInfo], isActive: Bool = true, onSelect: @escaping (GameInfo) -> Void) {
        self.init(games: games, isActive: isActive, onSelect: onSelect) { _ in EmptyView() }
    }
}
