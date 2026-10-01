//
//  Palette.swift
//  JarvisLocal
//
//  Nouveau système de couleurs moderne et futuriste
//

import SwiftUI

/// Palette de couleurs Jarvis - Design moderne et immersif
enum JarvisPalette {
    
    // MARK: - Primary Colors
    
    /// Cyan électrique - Couleur principale de Jarvis
    static let primary = Color(hex: "00D4FF")
    static let primaryDark = Color(hex: "0099CC")
    static let primaryLight = Color(hex: "66E5FF")
    static let primaryGlow = Color(hex: "00D4FF").opacity(0.3)
    static let primaryGlowStrong = Color(hex: "00D4FF").opacity(0.5)
    
    // MARK: - Accent Colors
    
    /// Violet néon - Actions secondaires
    static let accent = Color(hex: "7B61FF")
    static let accentDark = Color(hex: "5A3FE0")
    static let accentGlow = Color(hex: "7B61FF").opacity(0.3)
    
    // MARK: - Semantic Colors
    
    /// Vert menthe - Succès, validation
    static let success = Color(hex: "00FF94")
    static let successDark = Color(hex: "00CC75")
    static let successGlow = Color(hex: "00FF94").opacity(0.3)
    
    /// Or - Attention, warning
    static let warning = Color(hex: "FFB800")
    static let warningDark = Color(hex: "CC9300")
    static let warningGlow = Color(hex: "FFB800").opacity(0.3)
    
    /// Rouge corail - Erreur, danger
    static let danger = Color(hex: "FF4757")
    static let dangerDark = Color(hex: "CC3846")
    static let dangerGlow = Color(hex: "FF4757").opacity(0.3)
    
    // MARK: - Surface Colors (Dark Mode)
    
    /// Fond profond - Arrière-plan principal
    static let surface = Color(hex: "0F1115")
    static let surfaceLight = Color(hex: "1A1D23")
    static let surfaceElevated = Color(hex: "252930")
    static let surfaceHighlight = Color(hex: "2F343D")
    
    // MARK: - Surface Colors (Light Mode)
    
    static let surfaceLightMode = Color(hex: "F5F5F7")
    static let surfaceLightModeElevated = Color(hex: "FFFFFF")
    static let surfaceLightModeHighlight = Color(hex: "E5E5EA")
    
    // MARK: - Text Colors
    
    static let textPrimary = Color(hex: "FFFFFF")
    static let textSecondary = Color(hex: "A0A5B0")
    static let textTertiary = Color(hex: "6B7080")
    static let textQuaternary = Color(hex: "454A55")
    
    // MARK: - Text Colors (Light Mode)
    
    static let textPrimaryLight = Color(hex: "1D1D1F")
    static let textSecondaryLight = Color(hex: "6E6E73")
    static let textTertiaryLight = Color(hex: "86868B")
    
    // MARK: - Border & Divider
    
    static let border = Color(hex: "3E4450")
    static let borderLight = Color(hex: "4A5060")
    static let divider = Color(hex: "2F343D")
    
    // MARK: - Gradients
    
    static let primaryGradient = LinearGradient(
        colors: [primary, primaryDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let accentGradient = LinearGradient(
        colors: [accent, accentDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let surfaceGradient = LinearGradient(
        colors: [surfaceLight, surface],
        startPoint: .top,
        endPoint: .bottom
    )
    
    // MARK: - Dynamic Colors (Adapt to system appearance)
    
    static var dynamicSurface: Color {
        Color(nsColor: .windowBackgroundColor)
    }
    
    static var dynamicSurfaceElevated: Color {
        Color(nsColor: .controlBackgroundColor)
    }
    
    static var dynamicTextPrimary: Color {
        .primary
    }
    
    static var dynamicTextSecondary: Color {
        .secondary
    }
}

// MARK: - Color Extension for Hex Support

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
