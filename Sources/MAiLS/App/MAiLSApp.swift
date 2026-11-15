import AppKit
import SwiftUI

@main
struct MAiLSApp: App {
    @State private var model: AppModel

    init() {
        _ = NSApplication.shared  // Socle.apply() a besoin de NSApp, pas encore créé à ce stade
        Socle.apply()
        Socle.brand(Brand.name, color: Brand.logoColor)
        do {
            _model = State(initialValue: try AppModel.makeDefault())
        } catch {
            // Sans base de données l'appli ne peut rien faire : on le dit clairement plutôt que d'ouvrir une fenêtre vide.
            fputs("MAiLS : impossible d'ouvrir la base de données : \(error)\n", stderr)
            exit(1)
        }
    }

    var body: some Scene {
        Window(Brand.name, id: "main") {
            RootView().environment(model)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)  // la taille choisie par l'utilisateur ne change jamais d'elle-même
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Dans les menus, le nom reste en texte normal (règle Socle).
            CommandGroup(replacing: .appInfo) {
                Button(L("menu.about")) { About.show() }
            }
            CommandGroup(after: .textEditing) {
                Button(L("menu.search")) { model.focusSearch() }.keyboardShortcut("f")
                Button(L("menu.jump")) { model.focusJump() }.keyboardShortcut("j")
            }
            CommandMenu(L("menu.account")) {
                Button(L("menu.refresh")) { model.refresh() }.keyboardShortcut("r")
                Divider()
                Button(L("menu.editAccount")) { model.showSetup = true }
                Button(L("menu.removeAccount")) { model.showRemoveConfirmation = true }.disabled(model.account == nil)
            }
        }
    }
}
