//
//  ToolConfirmationView.swift
//  JarvisLocal
//
//  Created by Dimitri claverie on 05/07/2026.
//


import SwiftUI

/// Écran de confirmation avant l'exécution d'un tool sensible.
/// Remplace l'ancien .alert() système, trop étroit pour afficher un script AppleScript
/// ou le contenu d'une note en entier — ici le contenu complet est visible et sélectionnable
/// avant que l'utilisateur ne décide.
struct ToolConfirmationView: View {
    let request: ToolConfirmationRequest
    let onResolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirmation requise")
                        .font(.headline)
                    Text("Outil : \(request.toolName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView {
                Text(request.summary)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 80, maxHeight: 240)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )

            HStack {
                Spacer()
                Button("Annuler") { onResolve(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Confirmer") { onResolve(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}