//
//  Theme.swift
//  JarvisLocal
//
//  Created by Dimitri claverie on 06/07/2026.
//

import SwiftUI
import AppKit

/// Identité visuelle "Jarvis" : palette délibérée plutôt que les couleurs système par défaut,
/// pour que l'app ne ressemble pas à n'importe quelle fenêtre SwiftUI générique. Inspirée du
/// registre HUD holographique (cyan/ambre sur fond quasi-noir), pas d'un thème "chat" cutesy —
/// cohérent avec un assistant système, pas une messagerie.
enum JarvisTheme {
    // Fond quasi-noir plutôt que noir pur : évite l'effet "trou" sur un écran, garde une
    // profondeur perceptible entre les panneaux.
    static let background = Color(red: 0.043, green: 0.055, blue: 0.075)   // #0B0E13
    static let panel = Color(red: 0.071, green: 0.086, blue: 0.114)        // #12161D
    static let panelElevated = Color(red: 0.098, green: 0.114, blue: 0.145) // #191D25

    // Cyan arc-reactor : la seule couleur "signature" de l'app. Réservée aux éléments actifs
    // (statut connecté, écoute, streaming) — pas de décoration gratuite ailleurs.
    static let accent = Color(red: 0.298, green: 0.847, blue: 0.925)       // #4CD8EC
    static let accentDim = accent.opacity(0.35)

    // Ambre pour les états d'attention (outil en cours, confirmation requise) — jamais confondu
    // avec le cyan, jamais confondu avec le rouge d'erreur.
    static let amber = Color(red: 0.965, green: 0.702, blue: 0.302)        // #F6B34D
    static let danger = Color(red: 0.937, green: 0.396, blue: 0.373)       // #EF655F

    static let textPrimary = Color(red: 0.906, green: 0.929, blue: 0.949)  // #E7EDF2
    static let textSecondary = Color(red: 0.557, green: 0.612, blue: 0.667) // #8E9CAA
    static let textTertiary = Color(red: 0.373, green: 0.416, blue: 0.463) // #5F6A76
    static let divider = Color.white.opacity(0.08)

    // Équivalent NSColor pour les vues AppKit (NSTextView, etc.) qui ne voient pas le thème SwiftUI.
    // Les valeurs sont les mêmes que leurs équivalents SwiftUI ci-dessus.
    static let nsTextPrimary: NSColor = NSColor(srgbRed: 0.906, green: 0.929, blue: 0.949, alpha: 1)

    // Police utilitaire monospace pour tout ce qui relève du "système" (timestamps, statuts,
    // noms de tools) — renforce le registre technique sans en faire trop, réservé aux petits
    // éléments d'accompagnement, jamais au texte de conversation lui-même.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
