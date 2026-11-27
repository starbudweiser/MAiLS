import SwiftUI

/// Réglages (⌘,) : mise à jour automatique et manuelle.
struct UpdateSettingsView: View {
    @State private var updater = Updater.shared
    @State private var auto = Updater.shared.autoCheck

    private var status: String {
        switch updater.state {
        case .idle: return L("upd.version", updater.currentVersion)
        case .checking: return L("upd.checking")
        case .upToDate: return L("upd.uptodate", updater.currentVersion)
        case .available(let v): return L("upd.available", v)
        case .downloading: return L("upd.downloading")
        case .ready(let v): return L("upd.ready", v)
        case .failed(let e): return L("upd.failed", e)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            Text(L("upd.title")).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            Toggle(L("upd.auto"), isOn: $auto)
                .socle(Socle.T.body)
                .onChange(of: auto) { _, on in updater.autoCheck = on }
            HStack(spacing: Socle.M.space2) {
                Button(L("upd.check")) { Task { await updater.check() } }
                    .buttonStyle(SocleButtonStyle(.secondary))
                    .disabled(updater.state == .checking || updater.state == .downloading)
                if case .available(let v) = updater.state {
                    Button(L("upd.download", v)) { Task { await updater.download() } }
                        .buttonStyle(SocleButtonStyle(.primary))
                }
            }
            Text(status).socle(Socle.T.caption).foregroundStyle(Socle.C.textMuted)
        }
        .padding(Socle.M.space5)
        .frame(width: 420, alignment: .leading)
        .background(Socle.C.surface)
    }
}
