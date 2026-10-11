//
//  MenuFocusView.swift
//  MeloNX
//
//  Created by Stossy11 on 29/9/2026.
//

import SwiftUI
import Combine

private final class MenuNavigationBox {
    var handler: (MenuNavigation) -> Void = { _ in }
}

private struct MenuNavigationModifier: ViewModifier {
    let isActive: Bool
    let handler: (MenuNavigation) -> Void
    
    @State private var id = UUID()
    @State private var box = MenuNavigationBox()
    
    func body(content: Content) -> some View {
        box.handler = handler
        
        return content
            .onAppear { sync() }
            .onDisappear { ControllerManager.shared.endMenuNavigation(id) }
            .onChange(of: isActive) { _ in sync() }
    }
    
    private func sync() {
        guard isActive else {
            ControllerManager.shared.endMenuNavigation(id)
            
            return
        }
        
        ControllerManager.shared.beginMenuNavigation(id) { [box] event in
            box.handler(event)
        }
    }
}

extension View {
    func menuNavigation(isActive: Bool = true, _ handler: @escaping (MenuNavigation) -> Void) -> some View {
        modifier(MenuNavigationModifier(isActive: isActive, handler: handler))
    }
}

private struct MenuFocusScopeKey: EnvironmentKey {
    static let defaultValue: MenuFocusScope? = nil
}

extension EnvironmentValues {
    var menuFocusScope: MenuFocusScope? {
        get { self[MenuFocusScopeKey.self] }
        set { self[MenuFocusScopeKey.self] = newValue }
    }
}

private struct MenuFocusScopeModifier<Item: Identifiable>: ViewModifier {
    @StateObject private var scope = MenuFocusScope()
    @ObservedObject private var controllers = ControllerManager.shared
    
    let items: [Item]
    let scrollProxy: ScrollViewProxy?
    let isActive: Bool
    let onConfirm: (Item) -> Void
    let onCancel: (() -> Void)?
    
    private var ids: [AnyHashable] { items.map { AnyHashable($0.id) } }
    
    func body(content: Content) -> some View {
        content
            .environment(\.menuFocusScope, scope)
            .coordinateSpace(name: menuFocusCoordinateSpace)
            .onPreferenceChange(MenuFocusFramesKey.self) { scope.setFrames($0) }
            .onAppear { scope.setItems(ids) }
            .onChange(of: ids) { scope.setItems($0) }
            .onChange(of: isActive) { active in
                if !active { scope.clearFocus() }
            }
            .onChange(of: controllers.hasPhysicalController) { connected in
                if !connected { scope.clearFocus() }
            }
            .onChange(of: scope.focusedID) { focused in
                guard let focused, let scrollProxy else { return }
                
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollProxy.scrollTo(focused, anchor: .center)
                }
            }
            .menuNavigation(isActive: isActive) { event in
                handle(event)
            }
    }
    
    private func handle(_ event: MenuNavigation) {
        switch event {
        case .confirm:
            guard !scope.focusFirstIfNeeded() else { return }
            
            guard let focused = scope.focusedID,
                  let item = items.first(where: { AnyHashable($0.id) == focused }) else { return }
            
            onConfirm(item)
            
        case .cancel:
            onCancel?()
            
        case .up, .down, .left, .right:
            scope.move(event)
        }
    }
}

extension View {
    func menuFocusScope<Item: Identifiable>(
        items: [Item],
        scrollProxy: ScrollViewProxy? = nil,
        isActive: Bool = true,
        onConfirm: @escaping (Item) -> Void,
        onCancel: (() -> Void)? = nil
    ) -> some View {
        modifier(
            MenuFocusScopeModifier(
                items: items,
                scrollProxy: scrollProxy,
                isActive: isActive,
                onConfirm: onConfirm,
                onCancel: onCancel
            )
        )
    }
}


struct MenuFocusStyle {
    var cornerRadius: CGFloat = 12
    var inset: CGFloat = 4
    var lineWidth: CGFloat = 3
    var scale: CGFloat = 1.04
    
    static let card = MenuFocusStyle(cornerRadius: 16)
    static let smallCard = MenuFocusStyle(cornerRadius: 20)
    static let row = MenuFocusStyle(cornerRadius: 12, inset: 2, scale: 1.01)
}

private struct MenuFocusRing: ViewModifier {
    @ObservedObject var scope: MenuFocusScope
    
    let id: AnyHashable
    let style: MenuFocusStyle
    
    @Environment(\.appTheme) private var theme
    
    private var isFocused: Bool { scope.focusedID == id }
    
    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: style.cornerRadius + style.inset, style: .continuous)
                    .stroke(theme.accent.primary, lineWidth: style.lineWidth)
                    .padding(-style.inset)
                    .shadow(color: theme.accent.primary.opacity(0.5), radius: 8)
                    .opacity(isFocused ? 1 : 0)
            )
            .scaleEffect(isFocused ? style.scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
    }
}

private struct MenuFocusableModifier: ViewModifier {
    let id: AnyHashable
    let style: MenuFocusStyle
    
    @Environment(\.menuFocusScope) private var scope
    
    @ViewBuilder
    func body(content: Content) -> some View {
        if let scope {
            content
                .modifier(MenuFocusRing(scope: scope, id: id, style: style))
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: MenuFocusFramesKey.self,
                            value: [MenuFocusFrame(id: id, frame: geometry.frame(in: .named(menuFocusCoordinateSpace)))]
                        )
                    }
                )
                .id(id)
        } else {
            content
        }
    }
}

extension View {
    func menuFocusable<ID: Hashable>(_ id: ID, style: MenuFocusStyle = .card) -> some View {
        modifier(MenuFocusableModifier(id: AnyHashable(id), style: style))
    }
}
