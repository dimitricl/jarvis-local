import SwiftUI
import JarvisCore

/// Racine UI. Générique sur le settings (protocol) : la composition root
/// (exécutable) injecte le concret de JarvisServices ; les previews/tests
/// peuvent injecter un fake — ContentView ne nomme jamais JarvisServices.
/// Type public : instanciée par l'exécutable (composition root).
public struct ContentView<S: AppSettingsProtocol>: View {
    @Environment(AppViewModel.self) private var vm
    let settings: S
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    public init(settings: S) {
        self.settings = settings
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .frame(minWidth: 200, idealWidth: 220)
        } detail: {
            ChatView()
        }
        // Toolbar native (recette Apple) : contrôles standard en styles verre
        // système — le chrome vient du système, pas de pastilles manuelles.
        // 3 groupes max (HIG) : création | navigation | réglages.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { Task { await vm.newConversation() } }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.glassProminent)
                .tint(JarvisTheme.accent)
                .accessibilityLabel("Nouvelle conversation (/clear)")
                .help("Nouvelle conversation (/clear)")
            }
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { vm.showSearch.toggle() }) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Rechercher dans les conversations (/search)")
                .help("Rechercher dans les conversations (/search)")
                Button(action: { vm.showFacts.toggle() }) {
                    Image(systemName: "brain")
                }
                .buttonStyle(.glass)
                .tint(JarvisTheme.amber)
                .accessibilityLabel("Afficher la mémoire des faits (/facts)")
                .help("Mémoire des faits (/facts)")
                Button(action: { vm.showHelp.toggle() }) {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Aide des commandes (/help)")
                .help("Aide des commandes (/help)")
            }
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { vm.showSettings.toggle() }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Ouvrir les réglages")
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
        // Confirmation obligatoire avant toute action sensible (extinction, message, applescript, édition de note),
        // pour éviter qu'un modèle local halluciné exécute une action irréversible sans validation humaine.
        // Un .sheet plutôt qu'un .alert : un script AppleScript ou le contenu d'une note ne tient pas
        // dans une alerte système, l'utilisateur doit pouvoir lire ce qu'il valide en entier.
        .sheet(item: Binding(
            get: { vm.confirmationRequest },
            set: { if $0 == nil { vm.confirmationRequest?.resolve(false); vm.confirmationRequest = nil } }
        )) { request in
            ToolConfirmationView(request: request) { approved in
                request.resolve(approved)
                vm.confirmationRequest = nil
            }
        }
    }
}
