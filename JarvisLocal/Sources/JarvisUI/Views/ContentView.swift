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
        .toolbar {
            ToolbarItemGroup {
                Button(action: { vm.showSettings.toggle() }) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Ouvrir les réglages")
                .sheet(isPresented: Bindable(vm).showSettings) {
                    SettingsView(settings: settings)
                }
            }
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
