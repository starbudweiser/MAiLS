import MAiLSCore
import SwiftUI

/// Barre latérale : « Aller à un dossier » (⌘J), les dossiers principaux, les épinglés, puis l'arbre complet (une ligne par dossier).
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JumpField()
            if model.isJumping { JumpResults() } else { folderList }
            if let account = model.account {
                Text(L("sidebar.footer", account.username, model.folders.count))
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

    private var folderList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.mainFolders) { folder in
                        MainFolderRow(folder: folder, select: select).id("m:\(folder.id)")
                    }
                    if !model.pinnedFolders.isEmpty {
                        Eyebrow(L("sidebar.pinned"))
                        ForEach(model.pinnedFolders) { folder in
                            PinnedRow(folder: folder, select: select)
                        }
                    }
                    TreeHeader()
                    ForEach(model.treeRows) { row in
                        TreeRowView(row: row, select: select).id("t:\(row.id)")
                    }
                }
            }
            .scrollIndicators(.automatic)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
            .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
            .onKeyPress(.rightArrow) { model.expandOrDescend(); return .handled }
            .onKeyPress(.leftArrow) { model.collapseOrAscend(); return .handled }
            .onChange(of: model.selectedFolderID) { scrollToSelection(proxy) }
            // Après « Aller à un dossier » la liste vient de reparaître : elle défile elle aussi jusqu'au dossier choisi.
            .onAppear { scrollToSelection(proxy) }
        }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let folder = model.selectedFolder else { return }
        let target = folder.role == nil ? "t:\(folder.path)" : "m:\(folder.id)"
        // Laisse l'arbre se déplier avant de défiler jusqu'au dossier.
        Task { @MainActor in proxy.scrollTo(target) }
    }

    /// Un clic donne aussi le clavier à la liste : les flèches naviguent ensuite entre les dossiers.
    private func select(_ id: Int64) {
        model.selectFolder(id)
        listFocused = true
    }
}

private enum Layout {
    static let row: CGFloat = 28
    static let pinnedRow: CGFloat = 40
    static let chevron: CGFloat = 16
}

// MARK: Aller à un dossier

private struct JumpField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        TextField(L("sidebar.jump"), text: $model.jumpText)
            .socleField()
            .focused($focused)
            .onChange(of: model.focusJumpTick) { focused = true }
            .onKeyPress(.downArrow) { model.moveJumpSelection(1); return .handled }
            .onKeyPress(.upArrow) { model.moveJumpSelection(-1); return .handled }
            .onKeyPress(.escape) {
                model.jumpText = ""
                focused = false
                return .handled
            }
            .onSubmit {
                model.openJumpSelection()
                focused = false
            }
            .help(L("sidebar.jump.help"))
            .padding(Socle.M.space3)
    }
}

private struct JumpResults: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let results = model.jumpResults
        if results.isEmpty {
            Text(L("sidebar.noResults"))
                .socle(Socle.T.body)
                .foregroundStyle(Socle.C.textSubtle)
                .padding(.horizontal, Socle.M.space4)
                .padding(.top, Socle.M.space2)
            Spacer(minLength: 0)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, folder in
                            JumpResultRow(folder: folder, highlighted: index == model.jumpIndex).id(folder.id)
                        }
                    }
                }
                .onChange(of: model.jumpIndex) {
                    if results.indices.contains(model.jumpIndex) { proxy.scrollTo(results[model.jumpIndex].id) }
                }
            }
        }
    }
}

private struct JumpResultRow: View {
    @Environment(AppModel.self) private var model
    let folder: FolderSummary
    let highlighted: Bool

    var body: some View {
        Button { model.selectFolder(folder.id) } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Socle.M.space2) {
                    Text(model.displayName(for: folder))
                        .socle(folder.unreadCount > 0 ? Socle.T.labelStrong : Socle.T.label)
                        .foregroundStyle(Socle.C.textStrong)
                        .lineLimit(1)
                    Spacer(minLength: Socle.M.space2)
                    if folder.unreadCount > 0 {
                        Text("\(folder.unreadCount)").socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                    }
                }
                if let parent = parentPath {
                    Text(parent).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).lineLimit(1).truncationMode(.head)
                }
            }
            .padding(.horizontal, Socle.M.space4)
            .frame(height: Layout.pinnedRow)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Socle.C.surfaceSelected : .clear)
            .overlay(alignment: .leading) { if highlighted { Rectangle().fill(Socle.C.accent).frame(width: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folder.displayPath)
    }

    /// « ADMINISTRATIONS › BANQUE » : où se trouve le dossier (rien pour un dossier de premier niveau ou principal).
    private var parentPath: String? {
        guard folder.role == nil else { return nil }
        let names = FolderTree.breadcrumb(for: folder).dropLast().map(\.name)
        return names.isEmpty ? nil : names.joined(separator: " › ")
    }
}

// MARK: Rangées

private struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .socle(Socle.T.eyebrow)
            .foregroundStyle(Socle.C.textSubtle)
            .padding(.horizontal, Socle.M.space4)
            .padding(.top, Socle.M.space4)
            .padding(.bottom, Socle.M.space1)
    }
}

private struct TreeHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Socle.M.space2) {
            Text(L("sidebar.folders")).socle(Socle.T.eyebrow).foregroundStyle(Socle.C.textSubtle)
            Spacer(minLength: Socle.M.space2)
            iconButton("arrow.up.to.line", help: L("sidebar.collapseAll")) { model.collapseAll() }
            iconButton(model.hideEmptyFolders ? "eye.slash" : "eye", help: model.hideEmptyFolders ? L("sidebar.showEmpty") : L("sidebar.hideEmpty")) {
                model.hideEmptyFolders.toggle()
            }
        }
        .padding(.horizontal, Socle.M.space4)
        .padding(.top, Socle.M.space4)
        .padding(.bottom, Socle.M.space1)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(Socle.C.textMuted).frame(width: Layout.chevron, height: Layout.chevron)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Épingle ou retire des épinglés, au bout d'une ligne (sur un fond qui recouvre proprement ce qui passe dessous).
private struct PinButton: View {
    @Environment(AppModel.self) private var model
    let folder: FolderSummary
    let background: Color

    var body: some View {
        let label = folder.pinned ? L("sidebar.unpin") : L("sidebar.pin")
        Button { model.togglePin(folder) } label: {
            Image(systemName: folder.pinned ? "pin.slash" : "pin")
                .foregroundStyle(Socle.C.textMuted)
                .frame(width: Layout.chevron, height: Layout.row)
                .background(background)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Fond et barre d'accent communs : survol, sélection.
private struct RowChrome: ViewModifier {
    let selected: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        content
            .background(selected ? Socle.C.surfaceSelected : (hovering ? Socle.C.surfaceHover : .clear))
            .overlay(alignment: .leading) { if selected { Rectangle().fill(Socle.C.accent).frame(width: 2) } }
    }
}

private struct MainFolderRow: View {
    @Environment(AppModel.self) private var model
    let folder: FolderSummary
    let select: (Int64) -> Void
    @State private var hovering = false

    private var selected: Bool { folder.id == model.selectedFolderID }
    private var name: String { model.displayName(for: folder) }

    var body: some View {
        Button { select(folder.id) } label: {
            HStack(spacing: Socle.M.space2_5) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(selected ? Socle.C.textStrong : Socle.C.textMuted).accessibilityHidden(true)
                Text(name).socle(selected || folder.unreadCount > 0 ? Socle.T.labelStrong : Socle.T.label)
                    .foregroundStyle(selected ? Socle.C.textStrong : Socle.C.text)
                    .lineLimit(1)
                Spacer(minLength: Socle.M.space2)
                if folder.unreadCount > 0 {
                    Text("\(folder.unreadCount)").socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                }
            }
            .padding(.horizontal, Socle.M.space4)
            .frame(height: Socle.M.sizeControl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(RowChrome(selected: selected, hovering: hovering))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(folder.unreadCount > 0 ? L("sidebar.unread", name, folder.unreadCount) : name)
    }

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

/// Dossier épinglé : son nom, et sous le nom où il se trouve (deux « MAIF » ne se confondent pas).
private struct PinnedRow: View {
    @Environment(AppModel.self) private var model
    let folder: FolderSummary
    let select: (Int64) -> Void
    @State private var hovering = false

    private var selected: Bool { folder.id == model.selectedFolderID }
    private var parentPath: String? {
        let names = FolderTree.breadcrumb(for: folder).dropLast().map(\.name)
        return names.isEmpty ? nil : names.joined(separator: " › ")
    }

    var body: some View {
        HStack(spacing: Socle.M.space2) {
            Button { select(folder.id) } label: {
                HStack(spacing: Socle.M.space2_5) {
                    Image(systemName: "pin.fill").frame(width: 18).foregroundStyle(Socle.C.textMuted).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.displayName(for: folder))
                            .socle(selected || folder.unreadCount > 0 ? Socle.T.labelStrong : Socle.T.label)
                            .foregroundStyle(selected ? Socle.C.textStrong : Socle.C.text)
                            .lineLimit(1)
                        if let parentPath {
                            Text(parentPath).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).lineLimit(1).truncationMode(.head)
                        }
                    }
                    Spacer(minLength: Socle.M.space2)
                    if folder.unreadCount > 0 && !(hovering || selected) {
                        Text("\(folder.unreadCount)").socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Socle.M.space4)
        .frame(height: Layout.pinnedRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RowChrome(selected: selected, hovering: hovering))
        .overlay(alignment: .trailing) {
            if hovering || selected {
                PinButton(folder: folder, background: selected ? Socle.C.surfaceSelected : Socle.C.surfaceHover)
                    .padding(.trailing, Socle.M.space4)
            }
        }
        .onHover { hovering = $0 }
        .help(folder.displayPath)
        .accessibilityLabel(folder.unreadCount > 0 ? L("sidebar.unread", folder.displayPath, folder.unreadCount) : folder.displayPath)
    }
}

/// Une ligne de l'arbre : retrait par niveau, flèche pour déplier, nom sur une seule ligne, non lus, épingle au survol.
private struct TreeRowView: View {
    @Environment(AppModel.self) private var model
    let row: FolderRow
    let select: (Int64) -> Void
    @State private var hovering = false

    private var selected: Bool { row.folder != nil && row.folder?.id == model.selectedFolderID }
    /// L'épingle prend la place du nombre de non lus, au survol et sur le dossier ouvert.
    private var showPin: Bool { row.folder != nil && (hovering || selected) }
    private var fullPath: String { row.folder?.displayPath ?? MailboxText.decode(row.id) }

    var body: some View {
        HStack(spacing: Socle.M.space1_5) {
            Color.clear.frame(width: CGFloat(row.depth) * Socle.M.space3, height: 1)
            chevron
            Button { if let folder = row.folder { select(folder.id) } else { model.toggleExpanded(row.id) } } label: {
                HStack(spacing: Socle.M.space2) {
                    Image(systemName: "folder").frame(width: 16).foregroundStyle(selected ? Socle.C.textStrong : Socle.C.textMuted).accessibilityHidden(true)
                    Text(row.name)
                        .socle(selected || row.unread > 0 ? Socle.T.labelStrong : Socle.T.label)
                        .foregroundStyle(selected ? Socle.C.textStrong : Socle.C.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Socle.M.space2)
                    if row.unread > 0 && !showPin {
                        Text("\(row.unread)").socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.unread > 0 ? L("sidebar.unread", row.name, row.unread) : row.name)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .padding(.leading, Socle.M.space3)
        .padding(.trailing, Socle.M.space3)
        .frame(height: Layout.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RowChrome(selected: selected, hovering: hovering))
        .overlay(alignment: .trailing) {
            if showPin, let folder = row.folder {
                PinButton(folder: folder, background: selected ? Socle.C.surfaceSelected : Socle.C.surfaceHover)
                    .padding(.trailing, Socle.M.space3)
            }
        }
        .onHover { hovering = $0 }
        .help(fullPath)
        .contextMenu {
            if let folder = row.folder {
                Button(folder.pinned ? L("sidebar.unpin") : L("sidebar.pin")) { model.togglePin(folder) }
                Divider()
            }
            Button(L("sidebar.collapseAll")) { model.collapseAll() }
        }
    }

    @ViewBuilder private var chevron: some View {
        if row.hasChildren {
            Button { model.toggleExpanded(row.id) } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .foregroundStyle(Socle.C.textMuted)
                    .frame(width: Layout.chevron, height: Layout.row)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.isExpanded ? L("sidebar.collapse") : L("sidebar.expand"))
        } else {
            Color.clear.frame(width: Layout.chevron, height: 1)
        }
    }
}
