//
//  ModernSidebarView.swift
//  JarvisLocal
//
//  Sidebar moderne avec animations et design épuré
//

import SwiftUI
import JarvisCore

struct ModernSidebarView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var showMemory = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header avec avatar Jarvis
            sidebarHeader
            
            // Liste des conversations
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(vm.conversations) { conv in
                        ConversationCard(
                            title: conv.title,
                            preview: previewText(for: conv),
                            date: formatDate(conv.updatedAt),
                            isSelected: vm.currentConversation?.id == conv.id,
                            action: {
                                Task { await vm.selectConversation(conv) }
                            }
                        )
                        .slideIn(from: .leading)
                        .id(conv.id)
                    }
                    
                    if vm.conversations.isEmpty {
                        emptyState
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            
            // Section mémoire (collapsible)
            if showMemory {
                memorySection
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            
            Spacer()
            
            // Footer avec statut
            sidebarFooter
        }
        .background(JarvisPalette.surface)
        .frame(minWidth: 260, idealWidth: 280)
    }
    
    // MARK: - Header
    
    private var sidebarHeader: some View {
        VStack(spacing: 16) {
            // Avatar Jarvis animé
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(JarvisPalette.primaryGradient)
                        .frame(width: 48, height: 48)
                        .glow(color: JarvisPalette.primary, radius: 15)
                    
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
                .pulse(scale: 1.05)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("JARVIS")
                        .font(JarvisTypography.title3())
                        .foregroundStyle(JarvisPalette.textPrimary)
                        .tracking(1.5)
                    
                    Text("Assistant IA")
                        .font(JarvisTypography.footnote())
                        .foregroundStyle(JarvisPalette.textTertiary)
                }
                
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            
            // Nouvelle conversation button
            Button(action: { Task { await vm.newConversation() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Nouvelle conversation")
                        .font(JarvisTypography.buttonMedium())
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(JarvisPalette.primaryGradient)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(
            LinearGradient(
                colors: [JarvisPalette.surfaceElevated, JarvisPalette.surface],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
    
    // MARK: - Memory Section
    
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "brain.fill")
                    .foregroundStyle(JarvisPalette.accent)
                Text("Mémoire")
                    .font(JarvisTypography.captionEmphasized())
                    .foregroundStyle(JarvisPalette.textPrimary)
                Spacer()
                Button(action: { showMemory = false }) {
                    Image(systemName: "chevron.up")
                        .font(.caption)
                        .foregroundStyle(JarvisPalette.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            
            if vm.facts.isEmpty {
                Text("Aucun fait mémorisé")
                    .font(JarvisTypography.caption())
                    .foregroundStyle(JarvisPalette.textTertiary)
                    .padding(.horizontal, 24)
            } else {
                VStack(spacing: 4) {
                    ForEach(vm.facts) { fact in
                        HStack(spacing: 8) {
                            Text(fact.key + ":")
                                .font(JarvisTypography.monoLabel())
                                .foregroundStyle(JarvisPalette.primary)
                            Text(fact.value)
                                .font(JarvisTypography.caption())
                                .foregroundStyle(JarvisPalette.textSecondary)
                                .lineLimit(1)
                            Spacer()
                            Button(action: { Task { await vm.deleteFact(fact) } }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(JarvisPalette.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 4)
                    }
                }
            }
            
            Button(action: { Task { await vm.clearAllFacts() } }) {
                Text("Tout effacer")
                    .font(JarvisTypography.footnote())
                    .foregroundStyle(JarvisPalette.danger)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(JarvisPalette.surfaceElevated)
        .task { await vm.loadFacts() }
    }
    
    // MARK: - Footer
    
    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            // Toggle mémoire
            Button(action: { withAnimation { showMemory.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .foregroundStyle(showMemory ? JarvisPalette.accent : JarvisPalette.textSecondary)
                    Text("Mémoire")
                        .font(JarvisTypography.caption())
                        .foregroundStyle(showMemory ? JarvisPalette.accent : JarvisPalette.textSecondary)
                    Spacer()
                    Image(systemName: showMemory ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(JarvisPalette.textTertiary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            
            Divider()
                .background(JarvisPalette.divider)
            
            // Actions rapides
            HStack(spacing: 16) {
                ModernIconButton(icon: "magnifyingglass", style: .ghost) {
                    vm.showSearch.toggle()
                }
                .help("Rechercher")
                
                ModernIconButton(icon: "questionmark.circle", style: .ghost) {
                    vm.showHelp.toggle()
                }
                .help("Aide")
                
                Spacer()
                
                ModernIconButton(icon: "gearshape", style: .ghost) {
                    vm.showSettings.toggle()
                }
                .help("Réglages")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(JarvisPalette.surfaceElevated)
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(JarvisPalette.textTertiary)
            
            Text("Aucune conversation")
                .font(JarvisTypography.caption())
                .foregroundStyle(JarvisPalette.textTertiary)
        }
        .padding(.vertical, 32)
    }
    
    // MARK: - Helpers
    
    private func previewText(for conversation: Conversation) -> String {
        conversation.title.isEmpty ? "Nouvelle conversation" : conversation.title
    }
    
    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Hier"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "dd/MM"
            return formatter.string(from: date)
        }
    }
}


