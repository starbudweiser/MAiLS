import AppKit
import SwiftUI

/// Ajout (ou remplacement) du compte iCloud. Le mot de passe d'application part directement au Trousseau.
struct AccountSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            Text(L("setup.title")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            Text(L("setup.explain")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Socle.M.space2) {
                Text(L("setup.address")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted)
                TextField("", text: $username).socleField().textContentType(.username)
                Text(L("setup.password")).socle(Socle.T.label).foregroundStyle(Socle.C.textMuted).padding(.top, Socle.M.space2)
                SecureField("", text: $password).socleField()
                Button(L("setup.help")) {
                    if let url = URL(string: "https://support.apple.com/102654") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.plain)
                .socle(Socle.T.meta)
                .foregroundStyle(Socle.C.accentText)
            }

            if let error = model.setupError {
                Text(error).socle(Socle.T.body).foregroundStyle(Socle.C.danger)
            }

            HStack {
                Spacer()
                if model.account != nil {
                    Button(L("setup.cancel")) { model.showSetup = false; dismiss() }.buttonStyle(SocleButtonStyle(.secondary))
                }
                Button(L("setup.connect")) {
                    busy = true
                    Task {
                        await model.saveAccount(username: username, password: password)
                        busy = false
                        if !model.showSetup { password = "" }
                    }
                }
                .buttonStyle(SocleButtonStyle(.action))
                .disabled(busy)
            }
        }
        .padding(Socle.M.space6)
        .frame(width: 460)
        .background(Socle.C.surface)
        .onAppear { username = model.account?.username ?? username }
    }
}
