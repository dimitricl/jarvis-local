//
//  ModernChatView.swift
//  JarvisLocal
//
//  Chat moderne avec animations et design immersif
//

import SwiftUI
import JarvisCore

struct ModernChatView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var externalPrompt = ""
    @State private var scrollProxy: ScrollViewProxy?
    @Namespace private var animationNamespace
    
    var body: some View {
        VStack(spacing: 0) {
            // Header moderne
            modernHeader
            
            // Erreur banner
            if let error = vm.errorMessage {
                errorBanner(error)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            
            // Zone de messages
            messageList
            
            // Jobs de fond
            ModernJobsView()
            
            // Input bar moderne
            ModernInputBar(externalPrompt: $externalPrompt)
        }
        .background(JarvisPalette.surface)
    }
    
    // MARK: - Header
    
    private var modernHeader: some View {
        HStack(spacing: 16) {
            // Indicateur d'activité
            HStack(spacing: 8) {
                StatusIndicator(status: activityStatus, size: 8)
                Text(activityLabel)
                    .font(JarvisTypography.monoLabel())
                    .foregroundStyle(JarvisPalette.textSecondary)
                    .tracking(0.5)
            }
            
            // Badge modèle
            Text(vm.modelName.uppercased())
                .font(JarvisTypography.footnoteEmphasized())
                .foregroundStyle(JarvisPalette.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(JarvisPalette.surfaceElevated)
                .clipShape(Capsule())
            
            Spacer()
            
            // Titre conversation
            if let conv = vm.currentConversation {
                Text(conv.title)
                    .font(JarvisTypography.title3())
                    .foregroundStyle(JarvisPalette.textPrimary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Indicateurs vocaux
            HStack(spacing: 8) {
                if vm.isSpeaking {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                        Text("PARLE")
                    }
                    .font(JarvisTypography.monoLabel())
                    .foregroundStyle(JarvisPalette.warning)
                }
                
                if vm.isListening {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .font(.caption)
                        Text("ÉCOUTE")
                    }
                    .font(JarvisTypography.monoLabel())
                    .foregroundStyle(JarvisPalette.primary)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(JarvisPalette.surfaceElevated)
        .overlay(
            Rectangle()
                .fill(JarvisPalette.divider)
                .frame(height: 1),
            alignment: .bottom
        )
    }
    
    // MARK: - Error Banner
    
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(JarvisPalette.danger)
            Text(message)
                .font(JarvisTypography.caption())
                .foregroundStyle(JarvisPalette.danger)
            Spacer()
            Button(action: { vm.errorMessage = nil }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(JarvisPalette.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(JarvisPalette.danger.opacity(0.1))
        .overlay(
            Rectangle()
                .fill(JarvisPalette.danger)
                .frame(height: 1),
            alignment: .bottom
        )
    }
    
    // MARK: - Message List
    
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // État d'accueil
                    if vm.messages.isEmpty && vm.streamingText.isEmpty {
                        welcomeScreen
                            .frame(maxWidth: .infinity)
                    }
                    
                    // Messages
                    LazyVStack(spacing: 16) {
                        ForEach(vm.messages) { msg in
                            ModernMessageBubble(message: msg)
                                .id(msg.id)
                                .slideIn(from: .bottom)
                        }
                        
                        // Tool trace
                        if !vm.toolTrace.isEmpty {
                            toolTraceView
                        }
                        
                        // Streaming
                        if !vm.streamingText.isEmpty {
                            ModernMessageBubble(
                                text: vm.streamingText,
                                role: "assistant",
                                isStreaming: true
                            )
                            .id("streaming")
                        }
                        
                        // Indicateur de réflexion
                        if vm.isStreaming && vm.streamingText.isEmpty {
                            thinkingIndicator
                                .id("typing")
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
            .onChange(of: vm.messages.count) { _, _ in
                if let last = vm.messages.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: vm.streamingText) { _, _ in
                proxy.scrollTo("streaming", anchor: .bottom)
            }
            .onChange(of: vm.isStreaming) { _, streaming in
                if !streaming, let last = vm.messages.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    // MARK: - Welcome Screen
    
    private var welcomeScreen: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Logo animé
            ZStack {
                Circle()
                    .fill(JarvisPalette.primaryGradient)
                    .frame(width: 80, height: 80)
                    .glow(color: JarvisPalette.primary, radius: 30)
                
                Image(systemName: "bolt.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
            }
            .pulse(scale: 1.08)
            .padding(.top, 48)
            
            // Texte d'accueil
            VStack(spacing: 8) {
                Text("JARVIS")
                    .font(JarvisTypography.largeTitle())
                    .foregroundStyle(JarvisPalette.textPrimary)
                    .tracking(2)
                
                Text("Votre assistant IA personnel")
                    .font(JarvisTypography.body())
                    .foregroundStyle(JarvisPalette.textSecondary)
            }
            
            // Suggestions
            VStack(spacing: 8) {
                Text("Essayez:")
                    .font(JarvisTypography.caption())
                    .foregroundStyle(JarvisPalette.textTertiary)
                
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 8) {
                    suggestionCard("Quelle est la météo ?", icon: "cloud.sun")
                    suggestionCard("Crée un rappel", icon: "bell")
                    suggestionCard("Recherche web", icon: "globe")
                    suggestionCard("Ma liste de courses", icon: "list.bullet")
                }
            }
            .padding(.horizontal, 32)
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Suggestion Card
    
    private func suggestionCard(_ text: String, icon: String) -> some View {
        Button(action: { externalPrompt = text }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(JarvisPalette.primary)
                Text(text)
                    .font(JarvisTypography.caption())
                    .foregroundStyle(JarvisPalette.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(JarvisPalette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(JarvisPalette.border, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    // MARK: - Tool Trace
    
    private var toolTraceView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(JarvisPalette.textTertiary)
                .font(.caption)
            
            VStack(alignment: .leading, spacing: 4) {
                ForEach(vm.toolTrace) { entry in
                    HStack(spacing: 4) {
                        Text(entry.name)
                            .font(JarvisTypography.monoLabel())
                            .foregroundStyle(JarvisPalette.textSecondary)
                        Text(entry.status)
                            .font(JarvisTypography.monoLabel())
                            .foregroundStyle(statusColor(entry.status))
                        
                        if vm.isToolRunning && entry.id == vm.toolTrace.last?.id && entry.status == "…" {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(JarvisPalette.warning)
                        }
                    }
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(JarvisPalette.surfaceElevated.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    // MARK: - Thinking Indicator
    
    private var thinkingIndicator: some View {
        HStack(spacing: 8) {
            Text("Jarvis réfléchit")
                .font(JarvisTypography.caption())
                .foregroundStyle(JarvisPalette.textTertiary)
            
            ProgressView()
                .scaleEffect(0.8)
                .tint(JarvisPalette.primary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }
    
    // MARK: - Helpers
    
    private var activityStatus: StatusIndicator.Status {
        if vm.confirmationRequest != nil { return .error }
        if vm.isToolRunning { return .connecting }
        if vm.isStreaming { return .connecting }
        return .online
    }
    
    private var activityLabel: String {
        if vm.confirmationRequest != nil { return "CONFIRMATION" }
        if vm.isToolRunning { return "OUTIL: \(vm.currentToolName)" }
        if vm.isStreaming && vm.streamingText.isEmpty { return "RÉFLEXION" }
        if vm.isStreaming { return "RÉPONSE" }
        return "EN LIGNE"
    }
    
    private func statusColor(_ status: String) -> Color {
        switch status {
        case "✓": return JarvisPalette.success
        case "✗": return JarvisPalette.danger
        case "…": return JarvisPalette.warning
        default: return JarvisPalette.textSecondary
        }
    }
}

// MARK: - Modern Jobs View

struct ModernJobsView: View {
    @Environment(AppViewModel.self) private var vm

    private var activeJobs: [JobRecord] {
        vm.jobs.filter { !$0.status.isTerminal }
    }

    var body: some View {
        if !activeJobs.isEmpty {
            VStack(spacing: 4) {
                ForEach(activeJobs) { job in
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(JarvisPalette.primary)
                        
                        Text(job.title)
                            .font(JarvisTypography.caption())
                            .foregroundStyle(JarvisPalette.textSecondary)
                        
                        Spacer()
                        
                        Button(action: { Task { await vm.cancelJob(job.id) } }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(JarvisPalette.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(JarvisPalette.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }
}


