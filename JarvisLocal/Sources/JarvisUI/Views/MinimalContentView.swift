//
//  MinimalContentView.swift
//  JarvisLocal
//
//  ContentView refactorisé avec design minimaliste Apple
//

import SwiftUI
import JarvisCore

public struct MinimalContentView<S: AppSettingsProtocol>: View {
    @Environment(AppViewModel.self) private var vm
    let settings: S
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    public init(settings: S) {
        self.settings = settings
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MinimalSidebarView()
                .frame(minWidth: 200, idealWidth: 250)
        } detail: {
            MinimalChatView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { Task { await vm.newConversation() } }) {
                    Image(systemName: "plus")
                }
                .help("Nouvelle conversation")
            }
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { vm.showSearch.toggle() }) {
                    Image(systemName: "magnifyingglass")
                }
                .help("Rechercher")
                Button(action: { vm.showFacts.toggle() }) {
                    Image(systemName: "brain")
                }
                .help("Mémoire")
                Button(action: { vm.showHelp.toggle() }) {
                    Image(systemName: "questionmark.circle")
                }
                .help("Aide")
            }
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { vm.showSettings.toggle() }) {
                    Image(systemName: "gearshape")
                }
                .help("Réglages")
                .sheet(isPresented: Bindable(vm).showSettings) {
                    SettingsView(settings: settings)
                }
            }
        }
        .sheet(isPresented: Bindable(vm).showHelp) {
            HelpView()
        }
        .sheet(isPresented: Bindable(vm).showSearch) {
            SearchPanelView()
        }
        .sheet(isPresented: Bindable(vm).showTools) {
            ToolRunsPanel()
        }
        .sheet(item: Binding(
            get: { vm.confirmationRequest },
            set: { if $0 == nil { vm.confirmationRequest?.resolve(false); vm.confirmationRequest = nil } }
        )) { request in
            ToolConfirmationView(request: request) { approved in
                request.resolve(approved)
                vm.confirmationRequest = nil
            }
        }
        if !vm.healthIssues.isEmpty {
            healthBanner
        }
    }

    private var healthBanner: some View {
        HStack(spacing: MinimalTheme.spacingSM) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(MinimalTheme.warning)
            ForEach(vm.healthIssues) { issue in
                Text(issue.message)
                    .font(MinimalTheme.caption())
                    .foregroundStyle(MinimalTheme.text)
            }
            Spacer()
            if vm.isCheckingHealth {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Button("Réessayer") {
                    Task { await vm.runHealthCheck() }
                }
                .font(MinimalTheme.caption())
            }
        }
        .padding(.horizontal, MinimalTheme.spacingLG)
        .padding(.vertical, MinimalTheme.spacingSM)
        .background(MinimalTheme.warning.opacity(0.1))
    }
}
