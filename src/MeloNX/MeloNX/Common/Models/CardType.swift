//
//  CardType.swift
//  MeloNX
//
//  Created by Stossy11 on 23/4/2026.
//

import SwiftUI

public enum CardType: Codable, CaseIterable {
    case list
    case card
    case compactCard
    case compactCardNoBackground
    case compactCardSmall
    case carousel
    
    static var airplayCases: [CardType] {
        allCases
    }
    
    var gridColumns: [GridItem] {
        switch self {
        case .compactCardNoBackground: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)]
        case .compactCardSmall: [GridItem(.adaptive(minimum: 105, maximum: 120), spacing: 16)]
        default: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)]
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .list: "List"
        case .card: "Card"
        case .compactCard: "Compact Card"
        case .compactCardNoBackground: "Compact Card (No Background)"
        case .compactCardSmall: "Compact Card (Small)"
        case .carousel: "3D Cartridge"
        }
    }
}

