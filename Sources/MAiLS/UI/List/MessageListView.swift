import AppKit
import MAiLSCore
import SwiftUI

/// Colonne centrale : la liste des messages (ou « aucun message »).
struct MessageColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let folder = model.selectedFolder, folder.role == nil {
                PathBar(folder: folder)
                Rectangle().fill(Socle.C.border).frame(height: 1)
            }
            ZStack {
                MessageListView(model: model, query: model.query, revision: model.listRevision, role: currentRole)
                if model.listCount == 0, model.query != nil {
                    Text(model.query?.search == nil ? L("list.empty") : L("list.noResults"))
                        .socle(Socle.T.body)
                        .foregroundStyle(Socle.C.textSubtle)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Socle.C.surface)
    }

    private var currentRole: String? { model.folders.first(where: { $0.id == model.selectedFolderID })?.role }
}

/// Chemin du dossier ouvert, au-dessus de la liste : chaque niveau qui est un dossier se clique pour remonter.
private struct PathBar: View {
    @Environment(AppModel.self) private var model
    let folder: FolderSummary

    var body: some View {
        let all = FolderTree.breadcrumb(for: folder)
        // Les trois derniers niveaux ; les plus hauts se résument en « … » (le chemin complet est dans l'infobulle).
        let hidden = max(0, all.count - 3)
        let crumbs = Array(all.suffix(3))
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Socle.M.space1_5) {
                if hidden > 0 {
                    Text("…").foregroundStyle(Socle.C.textSubtle).help(folder.displayPath)
                }
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 || hidden > 0 { Text("›").foregroundStyle(Socle.C.textSubtle).accessibilityHidden(true) }
                    if index == crumbs.count - 1 {
                        Text(crumb.name).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                    } else if let target = model.folder(atPath: crumb.path) {
                        Button { model.selectFolder(target.id) } label: { Text(crumb.name).foregroundStyle(Socle.C.textMuted) }
                            .buttonStyle(.plain)
                    } else {
                        Text(crumb.name).foregroundStyle(Socle.C.textMuted)
                    }
                }
            }
            .socle(Socle.T.meta)
            .lineLimit(1)
            .padding(.horizontal, Socle.M.space4)
        }
        .defaultScrollAnchor(.trailing)
        .frame(height: Socle.M.sizeControl)
        .background(Socle.C.surfaceRaised)
    }
}

/// `NSTableView` paginée : 120 Hz sur des dizaines de milliers de messages. Seules les pages visibles (200 lignes) sont chargées.
struct MessageListView: NSViewRepresentable {
    let model: AppModel
    let query: MessageQuery?
    let revision: Int
    let role: String?

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ListTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = MessageCellView.height
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.setAccessibilityLabel(L("folder.inbox"))
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.sync(query: query, revision: revision, role: role)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let pageSize = 200
        let model: AppModel
        weak var table: NSTableView?
        private var query: MessageQuery?
        private var revision = -1
        private var role: String?
        private var rowCount = 0
        private var pages: [Int: [MessageSummary]] = [:]
        private var inFlight: Set<Int> = []
        private var generation = 0
        private var suppressSelection = false

        init(model: AppModel) { self.model = model }

        func sync(query: MessageQuery?, revision: Int, role: String?) {
            guard query != self.query || revision != self.revision || role != self.role else { return }
            let sameList = query == self.query
            self.query = query
            self.revision = revision
            self.role = role
            reload(keepSelection: sameList)
        }

        private func reload(keepSelection: Bool) {
            generation += 1
            let gen = generation
            guard let query else {
                rowCount = 0
                pages = [:]
                table?.reloadData()
                model.setListCount(0)
                return
            }
            let store = model.store
            Task { [weak self] in
                let count = (try? await store.count(query)) ?? 0
                guard let self, gen == self.generation, let table = self.table else { return }
                let oldCount = self.rowCount
                let selected = table.selectedRow
                self.rowCount = count
                self.pages = [:]
                self.inFlight = []
                self.suppressSelection = true
                table.reloadData()
                if keepSelection, selected >= 0 {
                    // Les nouveaux messages arrivent en haut : la ligne choisie descend d'autant.
                    let moved = selected + (count - oldCount)
                    if moved >= 0, moved < count { table.selectRowIndexes(IndexSet(integer: moved), byExtendingSelection: false) }
                } else if !keepSelection {
                    table.deselectAll(nil)
                    table.scrollRowToVisible(0)
                }
                self.suppressSelection = false
                self.model.setListCount(count)
            }
        }

        private func summary(at row: Int) -> MessageSummary? {
            pages[row / Self.pageSize]?[safe: row % Self.pageSize]
        }

        private func ensurePage(_ page: Int) {
            guard page >= 0, page * Self.pageSize < rowCount, pages[page] == nil, !inFlight.contains(page), let query else { return }
            inFlight.insert(page)
            let gen = generation
            let store = model.store
            Task { [weak self] in
                let rows = (try? await store.page(query, offset: page * Self.pageSize, limit: Self.pageSize)) ?? []
                guard let self, gen == self.generation, let table = self.table else { return }
                self.pages[page] = rows
                self.inFlight.remove(page)
                let range = (page * Self.pageSize)..<min(self.rowCount, (page + 1) * Self.pageSize)
                table.reloadData(forRowIndexes: IndexSet(integersIn: range), columnIndexes: IndexSet(integer: 0))
            }
        }

        // MARK: Source de données

        func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? MessageCellView) ?? MessageCellView()
            cell.identifier = id
            let page = row / Self.pageSize
            ensurePage(page)
            if row % Self.pageSize > Self.pageSize - 40 { ensurePage(page + 1) }
            if row % Self.pageSize < 40 { ensurePage(page - 1) }
            if let s = summary(at: row) { cell.configure(s, showRecipient: role == "sent" || role == "drafts") } else { cell.clear() }
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { MessageRowView() }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelection, let table else { return }
            let row = table.selectedRow
            if row < 0 { model.clearSelection(); return }
            if let s = summary(at: row) { model.open(s) }
        }
    }
}

/// `J` et `K` descendent et montent dans la liste (comme dans le PRD) ; les flèches fonctionnent déjà.
private final class ListTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return super.keyDown(with: event)
        }
        switch chars {
        case "j", "k":
            let target = selectedRow + (chars == "j" ? 1 : -1)
            guard target >= 0, target < numberOfRows else { return }
            selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            scrollRowToVisible(target)
        default:
            super.keyDown(with: event)
        }
    }
}

/// Ligne sélectionnée : aplat `surfaceSelected` et filet d'accent à gauche (Socle) ; jamais de surbrillance système.
private final class MessageRowView: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(Socle.C.surfaceSelected).setFill()
        bounds.fill()
        NSColor(Socle.C.accent).setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }

    override func drawSeparator(in dirtyRect: NSRect) {
        NSColor(Socle.C.borderSubtle).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override var isFlipped: Bool { true }
}

final class MessageCellView: NSTableCellView {
    static let height: CGFloat = 58
    private let dot = NSView()
    private let fromField = MessageCellView.label(Socle.T.label.nsFont)
    private let dateField = MessageCellView.label(Socle.T.meta.nsFont)
    private let subjectField = MessageCellView.label(Socle.T.body.nsFont)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dateField.alignment = .right
        [dot, fromField, dateField, subjectField].forEach(addSubview)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static func label(_ font: NSFont) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = font
        f.lineBreakMode = .byTruncatingTail
        f.usesSingleLineMode = true
        f.cell?.truncatesLastVisibleLine = true
        return f
    }

    func clear() {
        fromField.stringValue = ""
        dateField.stringValue = ""
        subjectField.stringValue = ""
        dot.isHidden = true
        setAccessibilityLabel(nil)
    }

    func configure(_ s: MessageSummary, showRecipient: Bool) {
        let unread = !s.flags.contains(.seen)
        let who: String
        if showRecipient, let to = s.toText, !to.isEmpty {
            who = L("list.to", to.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? to)
        } else {
            who = s.fromName ?? s.fromEmail ?? L("list.unknownSender")
        }
        let subject = s.subject.isEmpty ? L("list.noSubject") : s.subject
        let date = Self.dateText(s.sentAt)
        fromField.stringValue = who
        subjectField.stringValue = subject
        dateField.stringValue = date
        fromField.font = (unread ? Socle.T.labelStrong : Socle.T.label).nsFont
        fromField.textColor = NSColor(unread ? Socle.C.textStrong : Socle.C.textMuted)
        subjectField.textColor = NSColor(unread ? Socle.C.text : Socle.C.textSubtle)
        dateField.textColor = NSColor(Socle.C.textSubtle)
        dot.isHidden = !unread
        dot.layer?.backgroundColor = NSColor(Socle.C.accent).cgColor
        setAccessibilityLabel([unread ? "•" : nil, who, subject, date].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad = Socle.M.space3
        let textX = pad + 7 + Socle.M.space2
        let width = bounds.width
        dot.frame = NSRect(x: pad, y: 13, width: 7, height: 7)
        let dateWidth = min(110, ceil((dateField.stringValue as NSString).size(withAttributes: [.font: dateField.font as Any]).width) + 6)
        dateField.frame = NSRect(x: width - pad - dateWidth, y: 10, width: dateWidth, height: 16)
        fromField.frame = NSRect(x: textX, y: 8, width: max(0, width - textX - pad - dateWidth - Socle.M.space2), height: 18)
        subjectField.frame = NSRect(x: textX, y: 31, width: max(0, width - textX - pad), height: 17)
    }

    // MARK: Dates (aujourd'hui : heure ; hier ; cette semaine : jour ; sinon : date courte)

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE"); return f
    }()
    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f
    }()

    static func dateText(_ epoch: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        if calendar.isDate(date, inSameDayAs: now) { return timeFormatter.string(from: date) }
        if calendar.isDateInYesterday(date) { return L("date.yesterday") }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7, days > 0 {
            return weekdayFormatter.string(from: date)
        }
        return shortFormatter.string(from: date)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
