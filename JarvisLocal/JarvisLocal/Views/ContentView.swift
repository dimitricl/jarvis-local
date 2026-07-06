import SwiftUI

struct ContentView: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(Settings.self) private var settings
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
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
                .sheet(isPresented: Bindable(vm).showSettings) {
                    SettingsView()
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
