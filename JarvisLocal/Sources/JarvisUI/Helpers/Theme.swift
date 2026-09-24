//
//  Theme.swift
//  JarvisLocal
//
//  Created by Dimitri claverie on 06/07/2026.
//

import SwiftUI
import AppKit
import JarvisCore

/// Identité visuelle : plus de valeurs codées en dur — chaque token est une
/// couleur SÉMANTIQUE système qui s'adapte au mode clair/sombre/contraste
/// (recette Apple : jamais de composantes RGB figées).
/// L'identité restante, volontaire : teal système (actions), orange (attention),
/// rouge (danger), mono pour le registre technique. Le HUD holographique
/// opaque est abandonné au profit des backgrounds système base/élevé.
enum JarvisTheme {
    // Fond de fenêtre (base) + surfaces élevées : le système gère base/élevé
    // dans les deux apparences (en sombre, l'élevé est plus clair : la
    // profondeur est préservée sans coder deux palettes).
    static let background = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    // alternatingContentBackgroundColors est un tableau (lignes zébrées), pas une
    // couleur : controlColor (face des contrôles) comme neutre élevé L2.
    static let panelElevated = Color(nsColor: .controlColor)

    // Teal système (ex-bleu Messages) : actions, envoi, liens, statuts OK.
    // Système donc adaptatif clair/sombre/contraste augmenté, jamais de RGB figé.
    static let accent: Color = .teal
    static let accentDim = accent.opacity(0.35)

    // Orange = attention (outil en cours, confirmation, rappels) ; rouge = erreur.
    // Système, jamais confondus avec le teal, jamais confondus entre eux.
    static let amber: Color = .orange
    static let danger: Color = .red

    // Labels hiérarchiques système : contraste ≥ 4.5:1 garanti par le système
    // dans les deux apparences (plus de gris hardcodé qui se lave sur fond clair).
    static let textPrimary: Color = .primary
    static let textSecondary: Color = .secondary
    // Pas de Color.tertiary (ShapeStyle uniquement) : équivalent AppKit dynamique.
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let divider = Color(nsColor: .separatorColor)
    /// Fond de champ éditable (saisie, recherche vocale) : material texte système,
    /// pas un panneau — marelle blanche en clair, noire en sombre, comme TextField natif.
    static let fieldBackground = Color(nsColor: .textBackgroundColor)

    // Équivalent AppKit dynamique pour NSTextView (ne voit pas le thème SwiftUI).
    static let nsTextPrimary: NSColor = .labelColor

    // Police utilitaire monospace pour tout ce qui relève du "système" (timestamps, statuts,
    // noms de tools) — renforce le registre technique sans en faire trop, réservé aux petits
    // éléments d'accompagnement, jamais au texte de conversation lui-même.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
