import Foundation
import Testing

@testable import MAiLSCore

@Suite("HeaderParser")
struct HeaderParserTests {
    // MARK: RFC 2047

    @Test func motCodeBase64Utf8() {
        #expect(HeaderParser.decodeEncodedWords("=?UTF-8?B?w4lsb2RpZSBNYXJ0aW4=?=") == "Élodie Martin")
    }

    @Test func motCodeQLatin1() {
        #expect(HeaderParser.decodeEncodedWords("=?ISO-8859-1?Q?Chlo=E9_Dupont?=") == "Chloé Dupont")
    }

    @Test func motsAdjacentsRecolles() {
        // RFC 2047 §6.2 : l'espace entre deux mots codés disparaît.
        #expect(HeaderParser.decodeEncodedWords("=?utf-8?Q?Re=C3=A7u?= =?utf-8?Q?_hier?=") == "Reçu hier")
    }

    @Test func texteMelangeGardeSesEspaces() {
        #expect(HeaderParser.decodeEncodedWords("Re: =?utf-8?Q?caf=C3=A9?= du matin") == "Re: café du matin")
    }

    @Test func motCodeMalformeResteTelQuel() {
        #expect(HeaderParser.decodeEncodedWords("=?utf-8?Q?abc") == "=?utf-8?Q?abc")
        #expect(HeaderParser.decodeEncodedWords("=?inconnu-xyz?Q?abc?=") == "=?inconnu-xyz?Q?abc?=")
    }

    @Test func charsetsExotiques() {
        #expect(HeaderParser.decodeEncodedWords("=?windows-1252?Q?=80_5?=") == "€ 5")
        #expect(HeaderParser.decodeEncodedWords("=?utf-8*fr?Q?=C3=A9t=C3=A9?=") == "été")
        #expect(HeaderParser.decodeEncodedWords("=?ISO-2022-JP?B?GyRCRnxLXDhsGyhC?=") == "日本語")
    }

    @Test func base64SansPadding() {
        #expect(HeaderParser.decodeEncodedWords("=?utf-8?B?SGVsbG8?=") == "Hello")
    }

    // MARK: Adresses

    @Test func adresseSimple() {
        #expect(HeaderParser.parseAddresses("a@b.fr") == [MailAddress(name: nil, email: "a@b.fr")])
    }

    @Test func nomEtChevrons() {
        let r = HeaderParser.parseAddresses("Chloé Dupont <Chloe@Exemple.fr>")
        #expect(r == [MailAddress(name: "Chloé Dupont", email: "chloe@exemple.fr")])
    }

    @Test func nomEntreGuillemetsAvecVirgule() {
        let r = HeaderParser.parseAddresses("\"Dupont, Chloé\" <c@d.fr>, x@y.fr")
        #expect(r.count == 2)
        #expect(r[0].name == "Dupont, Chloé")
        #expect(r[1].email == "x@y.fr")
    }

    @Test func nomCodeEtCommentaire() {
        let r = HeaderParser.parseAddresses("=?UTF-8?B?w4lsb2RpZQ==?= <e@f.fr>, g@h.fr (Gérard)")
        #expect(r[0].name == "Élodie")
        #expect(r[1] == MailAddress(name: "Gérard", email: "g@h.fr"))
    }

    @Test func groupe() {
        let r = HeaderParser.parseAddresses("Équipe: a@b.fr, c@d.fr;")
        #expect(r.map(\.email) == ["a@b.fr", "c@d.fr"])
    }

    @Test func chevronsDansGuillemets() {
        let r = HeaderParser.parseAddresses("\"A <fake@evil.example>\" <real@ok.example>")
        #expect(r.first?.email == "real@ok.example")
    }

    @Test func listeVideOuIllisible() {
        #expect(HeaderParser.parseAddresses("").isEmpty)
        #expect(HeaderParser.parseAddresses(" , ; ").isEmpty)
    }

    // MARK: Dates

    @Test func dateAvecDecalage() {
        // 01 Jan 2024 02:01:00 +0200 == 00:01:00 UTC == 1704067260
        #expect(HeaderParser.parseDate("Mon, 01 Jan 2024 02:01:00 +0200") == 1_704_067_260)
    }

    @Test func dateSansJourEtAvecCommentaire() {
        #expect(HeaderParser.parseDate("1 Jan 2024 00:01:00 +0000 (UTC)") == 1_704_067_260)
    }

    @Test func dateZoneNommeeEtAnneeCourte() {
        #expect(HeaderParser.parseDate("Mon, 1 Jan 24 00:01 GMT") == 1_704_067_260)
        #expect(HeaderParser.parseDate("Sun, 31 Dec 2023 19:01:00 EST") == 1_704_067_260)
    }

    @Test func dateIllisible() {
        #expect(HeaderParser.parseDate("hier soir") == nil)
        #expect(HeaderParser.parseDate("") == nil)
        #expect(HeaderParser.parseDate("32 Jan 2024 00:00:00 +0000") == nil)
    }

    @Test func anneeBissextile() {
        #expect(HeaderParser.parseDate("29 Feb 2024 12:00:00 +0000") == 1_709_208_000)
    }

    // MARK: Bloc d'en-têtes complet

    @Test func blocComplet() {
        let raw = """
        From: =?ISO-8859-1?Q?Chlo=E9_Dupont?= <chloe@exemple.fr>\r
        To: stephan@exemple.fr, "Équipe, Projet" <equipe@exemple.fr> (liste)\r
        Subject:\r
         =?utf-8?Q?Confirmation_demande_commande_r=C3=A9union_photos_s=C3=A9curit=C3=A9?=\r
        Date: Mon, 01 Jan 2024 02:01:00 +0200\r
        Message-ID: <inbox.1.6232020@exemple.fr>\r
        In-Reply-To: <inbox.0@exemple.fr>\r
        References: <a@x> <b@x>\r
         <c@x>\r
        List-Unsubscribe: <mailto:stop@x.example>, <https://x.example/u/1>\r
        List-Unsubscribe-Post: List-Unsubscribe=One-Click\r
        \r

        """
        let h = HeaderParser.parse(Array(raw.utf8))
        #expect(h.from == MailAddress(name: "Chloé Dupont", email: "chloe@exemple.fr"))
        #expect(h.to.count == 2)
        #expect(h.to[1].name == "Équipe, Projet")
        #expect(h.subject == "Confirmation demande commande réunion photos sécurité")
        #expect(h.sentAt == 1_704_067_260)
        #expect(h.messageID == "inbox.1.6232020@exemple.fr")
        #expect(h.inReplyTo == "inbox.0@exemple.fr")
        #expect(h.references == ["a@x", "b@x", "c@x"])
        #expect(h.unsubscribeURL == "https://x.example/u/1")  // https préféré à mailto
        #expect(h.unsubscribeOneClick)
    }

    @Test func octets8BitsBrutsLatin1() {
        // Un vieil expéditeur envoie « é » en ISO-8859-1 brut (0xE9) : ne doit ni planter ni perdre la ligne.
        var raw = Array("Subject: Caf".utf8)
        raw.append(0xE9)
        raw += Array("\r\nFrom: a@b.fr\r\n\r\n".utf8)
        let h = HeaderParser.parse(raw)
        #expect(h.subject == "Café")
        #expect(h.from?.email == "a@b.fr")
    }

    @Test func enTeteSansDeuxPointsEtBlocVide() {
        #expect(HeaderParser.parse([]) == ParsedHeaders())
        let h = HeaderParser.parse(Array("ligne sans deux-points\r\nSubject: ok\r\n\r\n".utf8))
        #expect(h.subject == "ok")
    }

    @Test func arretALaLigneVide() {
        let h = HeaderParser.parse(Array("Subject: a\r\n\r\nSubject: corps\r\n".utf8))
        #expect(h.subject == "a")
    }

    @Test func injectionDansLeSujetNEstPasInterpretee() {
        // Le sujet est une donnée : jamais exécuté ni interprété, juste conservé tel quel.
        let h = HeaderParser.parse(Array("Subject: <script>alert(1)</script> '; DROP TABLE messages;--\r\n\r\n".utf8))
        #expect(h.subject == "<script>alert(1)</script> '; DROP TABLE messages;--")
    }
}
