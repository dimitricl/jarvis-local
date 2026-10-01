//
//  Spacing.swift
//  JarvisLocal
//
//  Système d'espacements cohérent
//

import SwiftUI

/// Système d'espacements Jarvis
enum JarvisSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    static let xxxl: CGFloat = 64
}

// MARK: - Corner Radius

enum JarvisCornerRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xlarge: CGFloat = 20
    static let full: CGFloat = 999
}

// MARK: - Shadow

enum JarvisShadow {
    static let small = CGSize(width: 0, height: 2)
    static let medium = CGSize(width: 0, height: 4)
    static let large = CGSize(width: 0, height: 8)
    static let xlarge = CGSize(width: 0, height: 16)
}


