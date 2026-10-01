//
//  ModernContentView.swift
//  JarvisLocal
//
//  ContentView moderne avec le nouveau design
//

import SwiftUI
import JarvisCore

public struct ModernContentView<S: AppSettingsProtocol>: View {
    @Environment(AppViewModel.self) private var vm
    let settings: S
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    
    public init(settings: S) {
        self.settings = settings
    }
    
    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ModernSidebarView()
                .frame(minWidth: 260, idealWidth: 280)
        } detail: {
            ModernChatView()
        }
        .toolbar {
            // Nouvelle conversation
            ToolbarItem(placement: .primaryAction) {
                ModernIconButton(icon: "plus", style: .primary) {
                    Task { await vm.newConversation() }
                }
                .help("Nouvelle conversation")
            }
            
            // Actions
            ToolbarItemGroup(placement: .automatic) {
                ModernIconButton(icon: "magnifyingglass", style: .ghost) {
                    vm.showSearch.toggle()
                }
                .help("Rechercher")
                
                ModernIconButton(icon: "brain", style: .ghost) {
                    vm.showFacts.toggle()
                }
                .help("Mémoire")
                
                ModernIconButton(icon: "questionmark.circle", style: .ghost) {
                    vm.showHelp.toggle()
                }
                .help("Aide")
            }
            
            // Réglages
            ToolbarItemGroup(placement: .automatic) {
                ModernIconButton(icon: "gearshape", style: .ghost) {
                    vm.showSettings.toggle()
                }
                .help("Réglages")
            }
        }
        .sheet(isPresented: Bindable(vm).showSettings) {
            ModernSettingsView(settings: settings)
        }
        .sheet(isPresented: Bindable(vm).showHelp) {
            ModernHelpView()
        }
        .sheet(isPresented: Bindable(vm).showSearch) {
            ModernSearchPanelView()
        }
        .sheet(isPresented: Bindable(vm).showTools) {
            ModernToolRunsPanel()
        }
        .sheet(item: Binding(
            get: { vm.confirmationRequest },
            set: { if $0 == nil { vm.confirmationRequest?.resolve(false); vm.confirmationRequest = nil } }
        )) { request in
            ModernToolConfirmationView(request: request) { approved in
                request.resolve(approved)
                vm.confirmationRequest = nil
            }
        }
        // Health banner
        if !vm.healthIssues.isEmpty {
            healthBanner
        }
    }
    
    // MARK: - Health Banner
    
    private var healthBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(JarvisPalette.warning)
            
            ForEach(vm.healthIssues) { issue in
                Text(issue.message)
                    .font(JarvisTypography.caption())
                    .foregroundStyle(JarvisPalette.textSecondary)
            }
            
            Spacer()
            
            if vm.isCheckingHealth {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Button("Réessayer") {
                    Task { await vm.runHealthCheck() }
                }
                .font(JarvisTypography.footnote())
                .foregroundStyle(JarvisPalette.primary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(JarvisPalette.warning.opacity(0.1))
        .overlay(
            Rectangle()
                .fill(JarvisPalette.warning)
                .frame(height: 1),
            alignment: .bottom
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Modern Settings View

struct ModernSettingsView<S: AppSettingsProtocol>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppViewModel.self) private var vm
    @Bindable var settings: S

    var body: some View {
        Form {
            Section("Général") {
                Toggle("Lancer au démarrage", isOn: $settings.launchAtLogin)
                    .accessibilityLabel("Lancer Jarvis au démarrage de la session")
                Text("Jarvis reste accessible depuis la barre de menu (icône waveform) même sans fenêtre ouverte.")
                    .font(JarvisTypography.footnote())
                    .foregroundStyle(JarvisPalette.textTertiary)
            }

            Section("Ollama") {
                TextField("URL :", text: $settings.ollamaURL)
                    .textFieldStyle(.roundedBorder)
                if !settings.ollamaHostIsLocal {
                    Text("Serveur distant : l'historique, les faits et les résultats d'outils sont envoyés à cet hôte. Local par défaut : http://localhost:11434.")
                        .font(JarvisTypography.footnote())
                        .foregroundStyle(JarvisPalette.warning)
                }
                TextField("Modèle principal :", text: $settings.model)
                    .textFieldStyle(.roundedBorder)
                TextField("Modèle rapide :", text: $settings.fastModel)
                    .textFieldStyle(.roundedBorder)
                Picker("Effort de raisonnement :", selection: $settings.reasoningEffort) {
                    Text("Aucun (rapide)").tag("none")
                    Text("Faible").tag("low")
                    Text("Moyen").tag("medium")
                    Text("Élevé").tag("high")
                }
                .pickerStyle(.menu)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Fenêtre de contexte (num_ctx) :")
                        Spacer()
                        Text("\(settings.numCtx) tokens")
                            .font(JarvisTypography.monoLabel())
                            .foregroundStyle(JarvisPalette.textSecondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.numCtx) },
                        set: { settings.numCtx = Int($0) }
                    ), in: 2048...32768, step: 1024)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Température (créativité) :")
                        Spacer()
                        Text(String(format: "%.1f", settings.temperature))
                            .font(JarvisTypography.monoLabel())
                            .foregroundStyle(JarvisPalette.textSecondary)
                    }
                    Slider(value: $settings.temperature, in: 0...2, step: 0.1)
                    Text("Bas (~0,2) = factuel. Haut = créatif mais confabulateur.")
                        .font(JarvisTypography.footnote())
                        .foregroundStyle(JarvisPalette.textTertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Longueur max de réponse :")
                        Spacer()
                        Text("\(settings.maxTokens) tokens")
                            .font(JarvisTypography.monoLabel())
                            .foregroundStyle(JarvisPalette.textSecondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.maxTokens) },
                        set: { settings.maxTokens = Int($0) }
                    ), in: 512...32768, step: 512)
                }
            }

            Section("Audio") {
                Toggle("Synthèse vocale (TTS)", isOn: $settings.ttsEnabled)
                Toggle("Reconnaissance vocale (STT)", isOn: $settings.voiceEnabled)
                if settings.ttsEnabled {
                    Picker("Voix TTS", selection: $settings.ttsVoiceIdentifier) {
                        Text("Auto (meilleure dispo)").tag("")
                        ForEach(settings.frenchVoiceOptions, id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.qualityLabel)) — \(voice.language)")
                                .tag(voice.identifier)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Section("MCP (iMCP, optionnel)") {
                Toggle("Activer MCP (redémarre l'app)", isOn: $settings.mcpEnabled)
                TextField("Chemin iMCP (vide = auto) :", text: $settings.imcpPath)
                    .textFieldStyle(.roundedBorder)
                    .font(JarvisTypography.monoLabel())
                Button("Réessayer la connexion MCP") {
                    Task { await vm.reconnectAll() }
                }
                .font(JarvisTypography.footnote())
            }

            Section("Boucle d'outils") {
                HStack {
                    Text("Max d'appels par outil et par tour :")
                    Spacer()
                    Text("\(settings.maxToolCallsPerTurn)")
                        .font(JarvisTypography.monoLabel())
                        .foregroundStyle(JarvisPalette.textSecondary)
                }
                Slider(value: Binding(
                    get: { Double(settings.maxToolCallsPerTurn) },
                    set: { settings.maxToolCallsPerTurn = Int($0) }
                ), in: 1...10, step: 1)
                Text("Coupe-circuit anti-boucle.")
                    .font(JarvisTypography.footnote())
                    .foregroundStyle(JarvisPalette.textTertiary)
            }

            Section("Mise à jour") {
                HStack {
                    Text("Version \(settings.currentVersion)")
                    Spacer()
                    if settings.isCheckingUpdate {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button(settings.updateAvailable ? "Mise à jour disponible !" : "Vérifier les mises à jour") {
                            Task { await settings.checkForUpdates() }
                        }
                    }
                }
                if let err = settings.updateCheckError {
                    Text(err)
                        .font(JarvisTypography.footnote())
                        .foregroundStyle(JarvisPalette.textSecondary)
                }
            }

            HStack {
                Spacer()
                ModernButton("Fermer", style: .secondary) { dismiss() }
            }
            .padding(.top, 8)
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 520)
        .background(JarvisPalette.surface)
    }
}

// MARK: - Modern Help View

struct ModernHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private struct CommandRow: Identifiable {
        let id = UUID()
        let command: String
        let description: String
    }

    private let commands: [CommandRow] = [
        .init(command: "/help", description: "Affiche cette aide"),
        .init(command: "/clear", description: "Démarre une nouvelle conversation"),
        .init(command: "/facts", description: "Affiche/masque la mémoire de faits personnels"),
        .init(command: "/search <texte>", description: "Recherche dans toutes les conversations"),
        .init(command: "/tools", description: "Audit : ce que Jarvis a VRAIMENT exécuté comme outils"),
        .init(command: "/export md", description: "Exporte la conversation en Markdown"),
        .init(command: "/export json", description: "Exporte la conversation en JSON"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(JarvisPalette.primary)
                Text("Commandes disponibles")
                    .font(JarvisTypography.title3())
                    .foregroundStyle(JarvisPalette.textPrimary)
                Spacer()
            }

            ModernCard(style: .flat) {
                VStack(spacing: 0) {
                    ForEach(commands) { cmd in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(cmd.command)
                                .font(JarvisTypography.monoLabel())
                                .foregroundStyle(JarvisPalette.primary)
                                .frame(width: 150, alignment: .leading)
                            Text(cmd.description)
                                .font(JarvisTypography.caption())
                                .foregroundStyle(JarvisPalette.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        if cmd.id != commands.last?.id {
                            Rectangle().fill(JarvisPalette.divider).frame(height: 1)
                        }
                    }
                }
            }

            Text("Astuce : Entrée pour envoyer, Cmd+Entrée pour un saut de ligne.")
                .font(JarvisTypography.footnote())
                .foregroundStyle(JarvisPalette.textTertiary)

            HStack {
                Spacer()
                ModernButton("Fermer", style: .secondary) { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(JarvisPalette.surface)
    }
}

// MARK: - Modern Search Panel

struct ModernSearchPanelView: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(JarvisPalette.primary)
                Text("Recherche")
                    .font(JarvisTypography.title3())
                    .foregroundStyle(JarvisPalette.textPrimary)
                Spacer()
            }

            HStack(spacing: 8) {
                TextField("Rechercher dans toutes les conversations...", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Rechercher dans toutes les conversations")
                    .onSubmit { Task { await vm.search(query) } }
                ModernButton("Chercher", style: .primary) { Task { await vm.search(query) } }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !vm.searchResults.isEmpty {
                Text("\(vm.searchResults.count) résultat(s) pour « \(vm.searchQuery) »")
                    .font(JarvisTypography.monoLabel())
                    .foregroundStyle(JarvisPalette.textTertiary)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    if vm.searchResults.isEmpty {
                        Text(vm.searchQuery.isEmpty ? "Tape ta recherche ci-dessus." : "Aucun résultat.")
                            .font(JarvisTypography.caption())
                            .foregroundStyle(JarvisPalette.textTertiary)
                            .padding(.top, 20)
                    }
                    ForEach(vm.searchResults) { result in
                        ModernSearchResultRow(entry: result)
                    }
                }
            }
            .frame(minHeight: 200)

            HStack {
                Spacer()
                ModernButton("Fermer", style: .secondary) { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(JarvisPalette.surface)
        .task {
            query = vm.searchQuery
            if !query.isEmpty && vm.searchResults.isEmpty {
                await vm.search(query)
            }
        }
    }
}

private struct ModernSearchResultRow: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let entry: AppViewModel.SearchResultEntry

    var body: some View {
        ModernCard(style: .flat) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.conversationTitle)
                        .font(JarvisTypography.monoLabel())
                        .foregroundStyle(JarvisPalette.primary)
                    Text(entry.role == "user" ? "VOUS" : "JARVIS")
                        .font(JarvisTypography.footnote())
                        .foregroundStyle(entry.role == "user" ? JarvisPalette.warning : JarvisPalette.textSecondary)
                        .padding(.horizontal, 6)
                        .background(JarvisPalette.surfaceHighlight)
                        .clipShape(Capsule())
                    Spacer()
                }
                Text(entry.content)
                    .font(JarvisTypography.caption())
                    .foregroundStyle(JarvisPalette.textPrimary)
                    .lineLimit(3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let cid = entry.conversationId,
               let conv = vm.conversations.first(where: { $0.id == cid }) {
                Task {
                    await vm.selectConversation(conv)
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Modern Tool Runs Panel

struct ModernToolRunsPanel: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(JarvisPalette.warning)
                Text("Outils exécutés")
                    .font(JarvisTypography.title3())
                    .foregroundStyle(JarvisPalette.textPrimary)
                Spacer()
                Button("Actualiser") { Task { await vm.loadToolRuns() } }
                    .font(JarvisTypography.footnote())
                    .foregroundStyle(JarvisPalette.primary)
                    .buttonStyle(.plain)
            }

            if vm.toolRuns.isEmpty {
                Text("Aucun outil exécuté pour l'instant. Les appels (réussis, refusés, échoués) apparaîtront ici.")
                    .font(JarvisTypography.caption())
                    .foregroundStyle(JarvisPalette.textTertiary)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(vm.toolRuns) { run in
                            runRow(run)
                        }
                    }
                }
                .frame(minHeight: 200, maxHeight: 420)
            }

            HStack {
                Spacer()
                ModernButton("Fermer", style: .secondary) { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 580)
        .background(JarvisPalette.surface)
        .task { await vm.loadToolRuns() }
    }

    private func runRow(_ run: ToolRun) -> some View {
        ModernCard(style: .flat) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(run.tool)
                        .font(JarvisTypography.monoLabel())
                        .foregroundStyle(JarvisPalette.textPrimary)
                    Text(run.status)
                        .font(JarvisTypography.monoLabel())
                        .foregroundStyle(statusColor(run.status))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(statusColor(run.status).opacity(0.12))
                        .clipShape(Capsule())
                    Spacer()
                    Text(Self.timestamp(run.createdAt))
                        .font(JarvisTypography.monoLabel())
                        .foregroundStyle(JarvisPalette.textTertiary)
                }
                if !run.args.isEmpty {
                    Text(run.args)
                        .font(JarvisTypography.monoLabel())
                        .foregroundStyle(JarvisPalette.textSecondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                if !run.result.isEmpty {
                    Text(run.result)
                        .font(JarvisTypography.footnote())
                        .foregroundStyle(JarvisPalette.textTertiary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "✓": JarvisPalette.success
        case "✗": JarvisPalette.danger
        case "refusé": JarvisPalette.warning
        default: JarvisPalette.textSecondary
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Modern Tool Confirmation View

struct ModernToolConfirmationView: View {
    let request: ToolConfirmationRequest
    let onApproval: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(JarvisPalette.warning)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirmation requise")
                        .font(JarvisTypography.title3())
                        .foregroundStyle(JarvisPalette.textPrimary)
                    Text("Outil : \(request.toolName)")
                        .font(JarvisTypography.caption())
                        .foregroundStyle(JarvisPalette.textSecondary)
                }
                Spacer()
            }

            ScrollView {
                Text(request.summary)
                    .font(JarvisTypography.monoLabel())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 80, maxHeight: 240)
            .background(JarvisPalette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(JarvisPalette.border, lineWidth: 1)
            )

            HStack {
                Spacer()
                ModernButton("Annuler", style: .secondary) { onApproval(false) }
                    .accessibilityLabel("Refuser l'action \(request.toolName)")
                ModernButton("Confirmer", style: .danger) { onApproval(true) }
                    .accessibilityLabel("Autoriser l'action \(request.toolName)")
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(JarvisPalette.surface)
    }
}
