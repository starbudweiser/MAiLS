import Testing

@testable import MAiLSCore

@Suite("Arbre des dossiers")
struct FolderTreeTests {
    private func folder(_ id: Int64, _ path: String, role: String? = nil, messages: Int = 5, unread: Int = 0, known: Bool = true) -> FolderSummary {
        FolderSummary(id: id, path: path, role: role, uidValidity: nil, messageCount: messages, unreadCount: unread, delimiter: "/", pinned: false, countsKnown: known)
    }

    private var sample: [FolderSummary] {
        [
            folder(1, "INBOX", role: "inbox"),
            folder(2, "ADMINISTRATIONS", messages: 0),
            folder(3, "ADMINISTRATIONS/BANQUE", messages: 0),
            folder(4, "ADMINISTRATIONS/BANQUE/PAYPAL", unread: 3),
            folder(5, "ADMINISTRATIONS/BANQUE/LCL", messages: 0),
            folder(6, "ADMINISTRATIONS/CAF", unread: 1),
            folder(7, "EMPLOI/FRANCE TRAVAIL", unread: 4),  // « EMPLOI » n'est pas listé : parent implicite
            folder(8, "ADMINISTRATIONS/&AMk-t&AOk-"),
        ]
    }

    @Test func arbreAvecParentsImplicitesEtOrdreNaturel() {
        let tree = FolderTree.build(sample)
        #expect(tree.map(\.name) == ["ADMINISTRATIONS", "EMPLOI"])  // la Réception (rôle) n'est pas dans l'arbre
        #expect(tree[1].folder == nil && tree[1].children.map(\.name) == ["FRANCE TRAVAIL"])
        #expect(tree[0].children.map(\.name) == ["BANQUE", "CAF", "Été"])  // accents décodés, ordre sans casse ni accents
        #expect(tree[0].unreadTotal == 4 && tree[1].unreadTotal == 4)
    }

    @Test func lignesSelonLesNiveauxDeplies() {
        let tree = FolderTree.build(sample)
        let closed = FolderTree.rows(tree, expanded: [], hideEmpty: false)
        #expect(closed.map(\.name) == ["ADMINISTRATIONS", "EMPLOI"])
        #expect(closed[0].hasChildren && !closed[0].isExpanded && closed[0].unread == 4)  // replié : total du contenu

        let open = FolderTree.rows(tree, expanded: ["ADMINISTRATIONS", "ADMINISTRATIONS/BANQUE"], hideEmpty: false)
        #expect(open.map(\.name) == ["ADMINISTRATIONS", "BANQUE", "LCL", "PAYPAL", "CAF", "Été", "EMPLOI"])
        #expect(open.map(\.depth) == [0, 1, 2, 2, 1, 1, 0])
        #expect(open[0].isExpanded && open[0].unread == 0)  // déplié : seulement ses propres messages
        #expect(open[1].unread == 0 && open[3].unread == 3)
    }

    @Test func dossiersVidesMasquesSansCacherLInconnu() {
        let tree = FolderTree.build(sample + [folder(9, "ADMINISTRATIONS/EDF", messages: 0, known: false)])
        let rows = FolderTree.rows(tree, expanded: ["ADMINISTRATIONS", "ADMINISTRATIONS/BANQUE"], hideEmpty: true)
        // LCL est vide : masqué. EDF : compteurs pas encore lus, donc affiché. BANQUE est vide mais garde PAYPAL, il reste.
        #expect(rows.map(\.name) == ["ADMINISTRATIONS", "BANQUE", "PAYPAL", "CAF", "EDF", "Été", "EMPLOI"])
        let onlyEmpty = FolderTree.rows(FolderTree.build([folder(1, "A", messages: 0), folder(2, "A/B", messages: 0)]), expanded: ["A"], hideEmpty: true)
        #expect(onlyEmpty.isEmpty)
    }

    @Test func dossierOuvertResteVisibleMemeVide() {
        let tree = FolderTree.build(sample)
        let open: Set<String> = ["ADMINISTRATIONS", "ADMINISTRATIONS/BANQUE"]
        let hidden = FolderTree.rows(tree, expanded: open, hideEmpty: true)
        #expect(!hidden.contains { $0.name == "LCL" })
        let kept = FolderTree.rows(tree, expanded: open, hideEmpty: true, keeping: ["ADMINISTRATIONS/BANQUE/LCL"])
        #expect(kept.map(\.name) == ["ADMINISTRATIONS", "BANQUE", "LCL", "PAYPAL", "CAF", "Été", "EMPLOI"])
        // Même sans dossier vide à garder, rien ne change.
        #expect(FolderTree.rows(tree, expanded: open, hideEmpty: false, keeping: ["EMPLOI"]).count == 7)
    }

    @Test func sousDossiersD_unDossierPrincipalSousLui() {
        let all = [
            folder(1, "INBOX", role: "inbox"), folder(2, "INBOX/Travail"), folder(3, "Archive", role: "archive"),
            folder(4, "Archive/2022"), folder(5, "Perso"),
        ]
        let tree = FolderTree.build(all) { $0.role == "inbox" ? "Réception" : $0.displayPath }
        #expect(tree.map(\.name) == ["Archive", "Perso", "Réception"])
        let inbox = tree.first { $0.name == "Réception" }
        // Le niveau porte le nom affiché, mais n'est pas un dossier : la Réception reste sélectionnable une seule fois, en haut.
        #expect(inbox?.folder == nil && inbox?.children.map(\.name) == ["Travail"])
        #expect(tree.contains { $0.id == "Archive" && $0.folder == nil })
        #expect(FolderTree.rows(tree, expanded: [], hideEmpty: false).allSatisfy { $0.folder?.role == nil })
        // Un dossier principal sans sous-dossier ne double pas son entrée fixe.
        #expect(FolderTree.build([folder(1, "INBOX", role: "inbox"), folder(5, "Perso")]).map(\.name) == ["Perso"])
    }

    @Test func parentSansEnfantVisibleDevientUneFeuille() {
        let tree = FolderTree.build([folder(1, "A"), folder(2, "A/B", messages: 0)])
        let rows = FolderTree.rows(tree, expanded: ["A"], hideEmpty: true)
        #expect(rows.count == 1 && !rows[0].hasChildren && !rows[0].isExpanded)
    }

    @Test func separateurPropreAuServeur() {
        var dotted = folder(1, "Perso.Voyages.Italie")
        dotted.delimiter = "."
        let tree = FolderTree.build([dotted])
        #expect(tree.map(\.name) == ["Perso"] && tree[0].children[0].children.map(\.name) == ["Italie"])
        #expect(FolderTree.breadcrumb(for: dotted).map(\.path) == ["Perso", "Perso.Voyages", "Perso.Voyages.Italie"])
    }

    @Test func cheminEtAncetres() {
        let f = folder(1, "ADMINISTRATIONS/BANQUE/&AMk-t&AOk-")
        let crumbs = FolderTree.breadcrumb(for: f)
        #expect(crumbs.map(\.name) == ["ADMINISTRATIONS", "BANQUE", "Été"])
        #expect(crumbs.map(\.path) == ["ADMINISTRATIONS", "ADMINISTRATIONS/BANQUE", "ADMINISTRATIONS/BANQUE/&AMk-t&AOk-"])
        #expect(FolderTree.ancestorPaths(of: f) == ["ADMINISTRATIONS", "ADMINISTRATIONS/BANQUE"])
    }

    @Test func rechercheDeDossier() {
        var all = sample
        all.append(folder(10, "PERSONNEL/PAYPAL"))
        let names: (FolderSummary) -> String = { $0.role == "inbox" ? "Réception" : $0.displayPath.components(separatedBy: "/").last ?? $0.path }
        func ids(_ q: String) -> [Int64] { FolderTree.search(all, query: q, displayName: names).map(\.id) }
        #expect(ids("pay") == [10, 4])                       // à égalité de nom, le moins profond d'abord
        #expect(ids("PAYPAL banque") == [4])                 // tous les mots, y compris dans un parent
        #expect(ids("ete") == [8])                           // sans accents ni casse
        #expect(ids("recep") == [1])                         // dossier principal par son nom affiché
        #expect(ids("banque") == [3, 5, 4])                  // le dossier lui-même, puis son contenu par ordre alphabétique
        #expect(ids("   ").isEmpty && ids("zzz").isEmpty)
        #expect(FolderTree.search(all, query: "a", limit: 2, displayName: names).count == 2)
    }
}
