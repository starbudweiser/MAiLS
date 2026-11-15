import AppKit
import MAiLSCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HeaderBar()
            Rectangle().fill(Socle.C.border).frame(height: 1)
            HSplitView {
                SidebarView().frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
                MessageColumn().frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
                ReaderView().frame(minWidth: 480, maxWidth: .infinity).layoutPriority(1)
            }
        }
        .background(Socle.C.bg)
        .background(WindowConfigurator())
        .sheet(isPresented: $model.showSetup) { AccountSetupView() }
        .alert(L("remove.title"), isPresented: $model.showRemoveConfirmation) {
            Button(L("remove.confirm"), role: .destructive) { Task { await model.removeAccount() } }
            Button(L("remove.cancel"), role: .cancel) {}
        } message: {
            Text(L("remove.message"))
        }
        .task { await model.start() }
    }
}

/// Barre d'en-tête Socle : 40 px sur toute la largeur.
private struct HeaderBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: Socle.M.space3) {
            Color.clear.frame(width: 70, height: 1)  // place des boutons de fenêtre
            Text(branded: Brand.name).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            Spacer(minLength: Socle.M.space4)
            StatusBadge()
            TextField(L("search.placeholder"), text: $model.searchText)
                .socleField()
                .focused($searchFocused)
                .frame(width: 300)
                .onChange(of: model.focusSearchTick) { searchFocused = true }
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .frame(width: Socle.M.sizeControl + 8)
            .buttonStyle(SocleButtonStyle(.secondary, height: Socle.M.sizeControl))
            .help(L("menu.refresh"))
            .accessibilityLabel(L("menu.refresh"))
        }
        .padding(.horizontal, Socle.M.space4)
        .frame(height: Socle.M.sizeBar)
        .background(Socle.C.surfaceRaised)
    }
}

/// État de la synchro : toujours une pastille ET des mots (jamais la couleur seule).
private struct StatusBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let (color, text) = content {
            HStack(spacing: Socle.M.space1_5) {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(text).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).lineLimit(1)
            }
            .frame(maxWidth: 360, alignment: .trailing)
        }
    }

    private var content: (Color, String)? {
        switch model.syncState {
        case .stopped: return nil
        case .needsPassword: return (Socle.C.warning, L("status.needsPassword"))
        case .connecting: return (Socle.C.warning, L("status.connecting"))
        case .syncing(let path, let fetched): return (Socle.C.warning, L("status.syncing", model.displayName(forPath: path), fetched))
        case .online: return (Socle.C.success, L("status.online"))
        case .offline(let detail): return (Socle.C.danger, L("status.offline", detail))
        case .authFailed: return (Socle.C.danger, L("status.authFailed"))
        }
    }
}

/// Réglages de la fenêtre : barre de titre fondue dans l'en-tête, déplaçable par l'en-tête, centrée au premier affichage (règle Socle).
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfigView: NSView {
        private var done = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !done else { return }
            done = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.styleMask.insert(.fullSizeContentView)
            window.minSize = NSSize(width: 1032, height: 640)
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.socleCenter()
        }
    }
}

extension AppModel {
    func displayName(forPath path: String) -> String {
        if let role = folders.first(where: { $0.path == path })?.role { return L("folder.\(role)") }
        return MailboxText.decode(path)
    }
}
