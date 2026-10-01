//
//  Typography.swift
//  JarvisLocal
//
//  Système de typographie moderne et cohérent
//

import SwiftUI

/// Système de typographie Jarvis
enum JarvisTypography {
    
    // MARK: - Display & Titles
    
    /// Grand titre pour les headers et écrans d'accueil
    static func largeTitle() -> Font {
        .system(size: 34, weight: .bold)
    }
    
    /// Titre principal pour les sections
    static func title1() -> Font {
        .system(size: 28, weight: .semibold)
    }
    
    /// Titre secondaire pour les sous-sections
    static func title2() -> Font {
        .system(size: 22, weight: .semibold)
    }
    
    /// Titre tertiaire pour les cards
    static func title3() -> Font {
        .system(size: 18, weight: .semibold)
    }
    
    // MARK: - Body Text
    
    /// Texte de corps standard
    static func body() -> Font {
        .system(size: 15, weight: .regular)
    }
    
    /// Texte de corps emphatisé
    static func bodyEmphasized() -> Font {
        .system(size: 15, weight: .medium)
    }
    
    /// Texte de corps bold
    static func bodyBold() -> Font {
        .system(size: 15, weight: .semibold)
    }
    
    // MARK: - Captions & Labels
    
    /// Légende standard
    static func caption() -> Font {
        .system(size: 13, weight: .regular)
    }
    
    /// Légende emphatisée
    static func captionEmphasized() -> Font {
        .system(size: 13, weight: .semibold)
    }
    
    /// Petit texte pour les métadonnées
    static func footnote() -> Font {
        .system(size: 11, weight: .regular)
    }
    
    /// Petit texte emphatisé
    static func footnoteEmphasized() -> Font {
        .system(size: 11, weight: .semibold)
    }
    
    // MARK: - Monospace (Technical)
    
    /// Police monospace pour le code, timestamps, logs
    static func mono(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    
    /// Monospace pour les labels techniques
    static func monoLabel() -> Font {
        mono(10, weight: .semibold)
    }
    
    /// Monospace pour les données
    static func monoData() -> Font {
        mono(12, weight: .regular)
    }
    
    // MARK: - Button Text
    
    /// Texte pour les boutons principaux
    static func buttonLarge() -> Font {
        .system(size: 17, weight: .semibold)
    }
    
    /// Texte pour les boutons secondaires
    static func buttonMedium() -> Font {
        .system(size: 15, weight: .medium)
    }
    
    /// Texte pour les petits boutons
    static func buttonSmall() -> Font {
        .system(size: 13, weight: .medium)
    }
}


