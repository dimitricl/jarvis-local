//
//  ModernButton.swift
//  JarvisLocal
//
//  Boutons modernes avec animations et effets
//

import SwiftUI

// MARK: - Button Styles

enum ModernButtonStyle {
    case primary
    case secondary
    case accent
    case danger
    case ghost
    case glass
}

struct ModernButton: View {
    let title: String
    let style: ModernButtonStyle
    let icon: String?
    let action: () -> Void
    @State private var isPressed = false
    
    init(_ title: String, style: ModernButtonStyle = .primary, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.icon = icon
        self.action = action
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(JarvisTypography.buttonMedium())
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(backgroundView)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
    
    private var foregroundColor: Color {
        switch style {
        case .primary, .accent, .danger:
            return .white
        case .secondary:
            return JarvisPalette.textPrimary
        case .ghost:
            return JarvisPalette.primary
        case .glass:
            return JarvisPalette.textPrimary
        }
    }
    
    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .primary:
            JarvisPalette.primaryGradient
                .shadow(color: JarvisPalette.primaryGlow, radius: isPressed ? 0 : 8, x: 0, y: 0)
        case .accent:
            JarvisPalette.accentGradient
                .shadow(color: JarvisPalette.accentGlow, radius: isPressed ? 0 : 8, x: 0, y: 0)
        case .danger:
            JarvisPalette.danger
                .shadow(color: JarvisPalette.dangerGlow, radius: isPressed ? 0 : 8, x: 0, y: 0)
        case .secondary:
            JarvisPalette.surfaceElevated
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(JarvisPalette.border, lineWidth: 1)
                )
        case .ghost:
            Color.clear
        case .glass:
            Color.white.opacity(0.1)
                .background(.ultraThinMaterial)
        }
    }
}

// MARK: - Icon Button

struct ModernIconButton: View {
    let icon: String
    let style: ModernButtonStyle
    let action: () -> Void
    @State private var isPressed = false
    
    init(icon: String, style: ModernButtonStyle = .ghost, action: @escaping () -> Void) {
        self.icon = icon
        self.style = style
        self.action = action
    }
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(foregroundColor)
                .frame(width: 36, height: 36)
                .background(backgroundView)
                .clipShape(Circle())
                .scaleEffect(isPressed ? 0.92 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
    
    private var foregroundColor: Color {
        switch style {
        case .primary, .accent:
            return .white
        case .danger:
            return JarvisPalette.danger
        case .secondary, .ghost, .glass:
            return JarvisPalette.textPrimary
        }
    }
    
    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .primary:
            JarvisPalette.primaryGradient
        case .accent:
            JarvisPalette.accentGradient
        case .danger:
            JarvisPalette.danger
        case .secondary:
            JarvisPalette.surfaceElevated
        case .ghost:
            Color.clear
        case .glass:
            Color.white.opacity(0.1)
                .background(.ultraThinMaterial)
        }
    }
}

// MARK: - Floating Action Button

struct ModernFAB: View {
    let icon: String
    let action: () -> Void
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(JarvisPalette.primaryGradient)
                .clipShape(Circle())
                .shadow(color: JarvisPalette.primaryGlowStrong, radius: isPressed ? 12 : 20, x: 0, y: 8)
                .scaleEffect(isPressed ? 0.92 : 1.0)
                .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}
