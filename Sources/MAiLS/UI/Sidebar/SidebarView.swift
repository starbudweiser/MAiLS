import MAiLSCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("sidebar.mailboxes"))
                .socle(Socle.T.eyebrow)
                .foregroundStyle(Socle.C.textSubtle)
                .padding(.horizontal, Socle.M.space4)
                .padding(.top, Socle.M.space4)
                .padding(.bottom, Socle.M.space2)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.folders) { folder in
                        FolderRow(folder: folder, selected: folder.id == model.selectedFolderID) { model.selectedFolderID = folder.id }
                            .padding(.top, folder.id == firstOtherFolderID ? Socle.M.space2 : 0)
                    }
                }
            }
            .scrollIndicators(.automatic)
            if let account = model.account {
                Text(account.username)
                    .socle(Socle.T.meta)
                    .foregroundStyle(Socle.C.textSubtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(Socle.M.space4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Socle.C.surfaceRaised)
    }

    /// Premier dossier hors des cinq principaux : un petit écart le sépare du groupe habituel.
    private var firstOtherFolderID: Int64? {
        model.folders.firstIndex(where: { !AppModel.isMainFolder($0) }).flatMap { $0 > 0 ? model.folders[$0].id : nil }
    }
}

private struct FolderRow: View {
    let folder: FolderSummary
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Socle.M.space2_5) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(selected ? Socle.C.textStrong : Socle.C.textMuted).accessibilityHidden(true)
                Text(name).socle(selected || folder.unreadCount > 0 ? Socle.T.labelStrong : Socle.T.label)
                    .foregroundStyle(selected ? Socle.C.textStrong : Socle.C.text)
                Spacer(minLength: Socle.M.space2)
                if folder.unreadCount > 0 {
                    Text("\(folder.unreadCount)").socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                }
            }
            .padding(.horizontal, Socle.M.space4)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Socle.C.surfaceSelected : (hovering ? Socle.C.surfaceHover : .clear))
            .overlay(alignment: .leading) { if selected { Rectangle().fill(Socle.C.accent).frame(width: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(folder.unreadCount > 0 ? "\(name), \(folder.unreadCount)" : name)
    }

    private var name: String { folder.role.map { L("folder.\($0)") } ?? folder.displayPath }

    private var icon: String {
        switch folder.role {
        case "inbox": "tray"
        case "sent": "paperplane"
        case "drafts": "doc"
        case "archive": "archivebox"
        case "trash": "trash"
        case "junk": "xmark.bin"
        default: "folder"
        }
    }
}
