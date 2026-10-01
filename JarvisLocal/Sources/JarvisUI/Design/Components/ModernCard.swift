//
//  ModernCard.swift
//  JarvisLocal
//
//  Cartes modernes avec effets de verre et animations
//

import SwiftUI

// MARK: - Card Styles

enum ModernCardStyle {
    case elevated
    case flat
    case glass
    case gradient
    case accent
}

struct ModernCard<Content: View>: View {
    let style: ModernCardStyle
    let content: Content
    @State private var isHovered = false
    
    init(style: ModernCardStyle = .elevated, @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(24)
            .background(backgroundView)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(borderColor, lineWidth: isHovered ? 2 : 1)
            )
            .shadow(color: shadowColor, radius: isHovered ? shadowRadius * 1.5 : shadowRadius, x: 0, y: shadowY)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
    
    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .elevated:
            JarvisPalette.surfaceElevated
        case .flat:
            JarvisPalette.surfaceLight
        case .glass:
            Color.white.opacity(0.05)
                .background(.ultraThinMaterial)
        case .gradient:
            JarvisPalette.surfaceGradient
        case .accent:
            JarvisPalette.accentGradient.opacity(0.15)
        }
    }
    
    private var borderColor: Color {
        switch style {
        case .elevated, .flat:
            return isHovered ? JarvisPalette.borderLight : JarvisPalette.border
        case .glass:
            return JarvisPalette.borderLight.opacity(0.5)
        case .gradient:
            return JarvisPalette.border
        case .accent:
            return JarvisPalette.accent.opacity(isHovered ? 0.5 : 0.3)
        }
    }
    
    private var shadowColor: Color {
        switch style {
        case .elevated, .flat:
            return Color.black.opacity(0.3)
        case .glass:
            return Color.black.opacity(0.2)
        case .gradient:
            return Color.black.opacity(0.25)
        case .accent:
            return JarvisPalette.accentGlow
        }
    }
    
    private var shadowRadius: CGFloat {
        switch style {
        case .elevated, .gradient:
            return 12
        case .flat:
            return 4
        case .glass:
            return 8
        case .accent:
            return 16
        }
    }
    
    private var shadowY: CGFloat {
        switch style {
        case .elevated, .gradient, .accent:
            return 4
        case .flat:
            return 2
        case .glass:
            return 3
        }
    }
}

// MARK: - Clickable Card

struct ClickableCard<Content: View>: View {
    let style: ModernCardStyle
    let action: () -> Void
    let content: Content
    @State private var isPressed = false
    
    init(style: ModernCardStyle = .elevated, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.style = style
        self.action = action
        self.content = content()
    }
    
    var body: some View {
        Button(action: action) {
            content
                .padding(24)
                .background(backgroundView)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(borderColor, lineWidth: isPressed ? 2 : 1)
                )
                .shadow(color: shadowColor, radius: isPressed ? shadowRadius * 0.5 : shadowRadius, x: 0, y: shadowY)
                .scaleEffect(isPressed ? 0.98 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
    
    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .elevated:
            JarvisPalette.surfaceElevated
        case .flat:
            JarvisPalette.surfaceLight
        case .glass:
            Color.white.opacity(0.05)
                .background(.ultraThinMaterial)
        case .gradient:
            JarvisPalette.surfaceGradient
        case .accent:
            JarvisPalette.accentGradient.opacity(0.15)
        }
    }
    
    private var borderColor: Color {
        switch style {
        case .elevated, .flat:
            return isPressed ? JarvisPalette.borderLight : JarvisPalette.border
        case .glass:
            return JarvisPalette.borderLight.opacity(0.5)
        case .gradient:
            return JarvisPalette.border
        case .accent:
            return JarvisPalette.accent.opacity(isPressed ? 0.7 : 0.3)
        }
    }
    
    private var shadowColor: Color {
        switch style {
        case .elevated, .gradient:
            return Color.black.opacity(0.3)
        case .flat:
            return Color.black.opacity(0.2)
        case .glass:
            return Color.black.opacity(0.15)
        case .accent:
            return JarvisPalette.accentGlow
        }
    }
    
    private var shadowRadius: CGFloat {
        switch style {
        case .elevated, .gradient:
            return 12
        case .flat:
            return 4
        case .glass:
            return 8
        case .accent:
            return 16
        }
    }
    
    private var shadowY: CGFloat {
        switch style {
        case .elevated, .gradient, .accent:
            return 4
        case .flat:
            return 2
        case .glass:
            return 3
        }
    }
}

// MARK: - Conversation Card

struct ConversationCard: View {
    let title: String
    let preview: String
    let date: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        ClickableCard(style: isSelected ? .accent : .elevated, action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title)
                        .font(JarvisTypography.title3())
                        .foregroundStyle(isSelected ? JarvisPalette.accent : JarvisPalette.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(date)
                        .font(JarvisTypography.footnote())
                        .foregroundStyle(JarvisPalette.textTertiary)
                }
                Text(preview)
                    .font(JarvisTypography.caption())
                    .foregroundStyle(JarvisPalette.textSecondary)
                    .lineLimit(2)
            }
        }
    }
}
