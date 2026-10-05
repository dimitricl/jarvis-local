//
//  MinimalTheme.swift
//  JarvisLocal
//
//  Système de design minimaliste dans le style Apple
//

import SwiftUI

/// Thème minimaliste Apple - Épuré, moderne, focalisé sur le contenu
enum MinimalTheme {

    // MARK: - Colors

    /// Couleur d'accent principale - Bleu Apple
    static let accent = Color.blue
    static let accentSecondary = Color.accentColor

    /// Couleurs sémantiques
    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red

    /// Surfaces
    static let background = Color(NSColor.windowBackgroundColor)
    static let secondaryBackground = Color(NSColor.controlBackgroundColor)
    static let tertiaryBackground = Color(NSColor.textBackgroundColor)

    /// Texte
    static let text = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.secondary.opacity(0.6)

    /// Bordures et séparateurs
    static let separator = Color.gray.opacity(0.2)
    static let border = Color.gray.opacity(0.3)

    // MARK: - Typography

    /// Titre principal
    static func largeTitle() -> Font {
        .largeTitle
    }

    /// Titre
    static func title() -> Font {
        .title
    }

    /// Titre secondaire
    static func title2() -> Font {
        .title2
    }

    /// Titre tertiaire
    static func title3() -> Font {
        .title3
    }

    /// Texte de corps
    static func body() -> Font {
        .body
    }

    /// Texte de corps emphatisé
    static func bodyEmphasized() -> Font {
        .body.weight(.medium)
    }

    /// Légende
    static func caption() -> Font {
        .caption
    }

    /// Légende emphatisée
    static func captionEmphasized() -> Font {
        .caption.weight(.medium)
    }

    /// Monospace pour le code
    static func mono(_ size: CGFloat = 11) -> Font {
        .system(.body, design: .monospaced)
    }

    // MARK: - Spacing

    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 16
    static let spacingLG: CGFloat = 24
    static let spacingXL: CGFloat = 32

    // MARK: - Corner Radius

    static let cornerRadiusSM: CGFloat = 6
    static let cornerRadiusMD: CGFloat = 8
    static let cornerRadiusLG: CGFloat = 12

    // MARK: - Components

    /// Style de bouton minimaliste
    static func buttonBackgroundColor(isPrimary: Bool = false) -> Color {
        if isPrimary {
            return accent
        } else {
            return secondaryBackground
        }
    }

    /// Style de carte minimaliste
    static func cardBackgroundColor() -> Color {
        return secondaryBackground
    }
}
