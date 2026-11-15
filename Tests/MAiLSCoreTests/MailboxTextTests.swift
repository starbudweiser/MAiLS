import Testing

@testable import MAiLSCore

@Suite("Noms de dossiers (UTF-7 modifié)")
struct MailboxTextTests {
    @Test func accentsDecodes() {
        #expect(MailboxText.decode("&AMk-t&AOk-") == "Été")
        #expect(MailboxText.decode("Courrier &AOk-lectronique") == "Courrier électronique")
        #expect(MailboxText.decode("Factures/&AMk-t&AOk- 2025") == "Factures/Été 2025")
    }

    @Test func esperluetteEtTexteSimpleInchanges() {
        #expect(MailboxText.decode("INBOX") == "INBOX")
        #expect(MailboxText.decode("Ventes &- Achats") == "Ventes & Achats")
    }

    @Test func caracteresHorsDuPlanDeBase() {
        // « 😀 » (U+1F600) : paire de substituts UTF-16 D83D DE00 → base 64 « 2D3eAA ».
        #expect(MailboxText.decode("&2D3eAA-") == "😀")
        // « ï¿¿ » (U+FFFF) donne « /// » en base 64 ; en UTF-7 modifié la barre devient une virgule.
        #expect(MailboxText.decode("&,,8-") == "\u{FFFF}")
    }

    @Test func sequencesInvalidesLaisseesTellesQuelles() {
        #expect(MailboxText.decode("Brouillon &AMk") == "Brouillon &AMk")  // pas de « - » final
        #expect(MailboxText.decode("A&!!!-B") == "A&!!!-B")  // pas de la base 64
    }
}
