import Foundation
import Testing

@testable import MAiLSCore

@Suite("MIME")
struct MIMETests {
    private func bytes(_ s: String) -> [UInt8] { Array(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

    @Test func texteSimpleUtf8() {
        let m = MIMEParser.parse(bytes("From: a@b.fr\nSubject: Salut\nContent-Type: text/plain; charset=utf-8\n\nBonjour é à\n"))
        #expect(m.plainText.contains("Bonjour é à"))
        #expect(m.headers.subject == "Salut")
        #expect(m.attachments.isEmpty)
    }

    @Test func quotedPrintableLatin1() {
        let m = MIMEParser.parse(bytes("Content-Type: text/plain; charset=iso-8859-1\nContent-Transfer-Encoding: quoted-printable\n\nCaf=E9 =\ncr=E8me\n"))
        #expect(m.plainText.contains("Café crème"))
    }

    @Test func base64EtCharsetInconnuRetombeSurUtf8() {
        let body = Data("Héllo".utf8).base64EncodedString()
        let m = MIMEParser.parse(bytes("Content-Type: text/plain; charset=x-inconnu\nContent-Transfer-Encoding: base64\n\n\(body)\n"))
        #expect(m.plainText.contains("Héllo"))
    }

    @Test func alternativeTextePuisHtml() {
        let raw = """
        Content-Type: multipart/alternative; boundary="b1"

        --b1
        Content-Type: text/plain; charset=utf-8

        Version texte
        --b1
        Content-Type: text/html; charset=utf-8

        <p>Version <b>HTML</b></p>
        --b1--
        """
        let m = MIMEParser.parse(bytes(raw))
        #expect(m.plainText.contains("Version texte"))
        #expect(m.html.contains("<b>HTML</b>"))
    }

    @Test func pieceJointeEtImageIntegree() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).base64EncodedString()
        let raw = """
        Content-Type: multipart/mixed; boundary="m"

        --m
        Content-Type: multipart/related; boundary="r"

        --r
        Content-Type: text/html

        <img src="cid:logo@x">
        --r
        Content-Type: image/png
        Content-ID: <logo@x>
        Content-Transfer-Encoding: base64

        \(png)
        --r--
        --m
        Content-Type: application/pdf; name="facture.pdf"
        Content-Disposition: attachment; filename="facture.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --m--
        """
        let m = MIMEParser.parse(bytes(raw))
        #expect(m.attachments.contains { $0.filename == "facture.pdf" && $0.size == 9 && !$0.isInline })
        #expect(m.inlineImages["logo@x"]?.data.count == 8)
        let readable = ReadableMessage.make(from: bytes(raw))
        #expect(readable.attachments.map(\.filename) == ["facture.pdf"])  // l'image intégrée n'est pas une « pièce jointe »
    }

    @Test func nomDeFichierRFC2231() {
        let raw = """
        Content-Type: multipart/mixed; boundary="m"

        --m
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename*=utf-8''r%C3%A9sum%C3%A9%20final.txt

        x
        --m--
        """
        #expect(MIMEParser.parse(bytes(raw)).attachments.first?.filename == "résumé final.txt")
    }

    @Test func nomDeFichierEnPlusieursMorceaux() {
        let raw = """
        Content-Type: multipart/mixed; boundary="m"

        --m
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename*0*=utf-8''tr%C3%A8s; filename*1*=%20long.txt

        x
        --m--
        """
        #expect(MIMEParser.parse(bytes(raw)).attachments.first?.filename == "très long.txt")
    }

    @Test func fermetureDeLimiteManquanteNePlantePas() {
        let m = MIMEParser.parse(bytes("Content-Type: multipart/mixed; boundary=\"z\"\n\n--z\nContent-Type: text/plain\n\ncorps sans fin\n"))
        #expect(m.plainText.contains("corps sans fin"))
    }

    @Test func profondeurEtNombreDePartiesBornes() {
        var raw = ""
        for i in 0..<30 { raw += "Content-Type: multipart/mixed; boundary=\"b\(i)\"\n\n--b\(i)\n" }
        raw += "Content-Type: text/plain\n\nfond\n"
        let m = MIMEParser.parse(bytes(raw))
        #expect(m.truncated)  // 30 niveaux > limite 10 : pas de récursion sans fin

        var many = "Content-Type: multipart/mixed; boundary=\"m\"\n\n"
        for i in 0..<400 { many += "--m\nContent-Type: text/plain\n\npartie \(i)\n" }
        many += "--m--\n"
        let big = MIMEParser.parse(bytes(many))
        #expect(big.truncated)
        #expect(big.plainText.contains("partie 0"))
    }

    @Test func entreesAbsurdesNePlantentPas() {
        for input in ["", "\n\n", "Content-Type: multipart/mixed\n\nx", "Content-Type: ;;;==\n\nx", "\u{0}\u{1}\u{2}", String(repeating: "A", count: 100_000)] {
            _ = MIMEParser.parse(bytes(input))
            _ = ReadableMessage.make(from: bytes(input))
        }
    }

    @Test func messageComplet() {
        let r = ReadableMessage.make(from: bytes("From: =?utf-8?Q?Zo=C3=AB?= <z@x.fr>\nSubject: Test\nDate: Mon, 01 Jan 2024 00:01:00 +0000\nContent-Type: text/plain\n\nLe texte de plus de vingt caractères.\nhttps://exemple.fr/page.\n"))
        #expect(r.headers.from?.name == "Zoë")
        #expect(r.readingText.contains("Le texte"))
        #expect(r.links.map(\.url) == ["https://exemple.fr/page"])  // ponctuation finale retirée
        #expect(!r.hasHTML)
        #expect(r.originalHTML.contains("<pre>"))
    }
}

@Suite("HTMLText")
struct HTMLTextTests {
    @Test func structureEtEntites() {
        let out = HTMLText.convert("<h1>Titre</h1><p>Un &amp; deux&nbsp;trois &eacute;t&#233; &#x41;</p><ul><li>un</li><li>deux</li></ul>")
        #expect(out.text == "Titre\n\nUn & deux trois été A\n\n• un\n• deux")
    }

    @Test func scriptsStylesEtContenuCacheIgnores() {
        let html = "<style>p{color:red}</style><script>alert(1)</script><div style=\"display:none\">PREHEADER</div><p>Visible</p><span hidden>caché</span>"
        let out = HTMLText.convert(html)
        #expect(out.text == "Visible")
    }

    @Test func liensAvecAdresseReelle() {
        let out = HTMLText.convert("<a href=\"https://banque.example/login\">https://ma-banque.fr</a> <a href=\"javascript:alert(1)\">piège</a> <a href=\"java\tscript:x\">piège2</a>")
        #expect(out.links == [HTMLText.Link(label: "https://ma-banque.fr", url: "https://banque.example/login")])
    }

    @Test func citationsListesNumerotees() {
        let out = HTMLText.convert("<blockquote>cité<br>encore</blockquote><ol><li>a</li><li>b</li></ol>")
        #expect(out.text.contains("> cité"))
        #expect(out.text.contains("1. a"))
        #expect(out.text.contains("2. b"))
    }

    @Test func pixelsDeSuiviJamaisEnTexte() {
        let out = HTMLText.convert("<p>Bonjour</p><img src=\"https://t.example/p.gif\" width=\"1\" height=\"1\" alt=\"pixel\"><img src=\"x\" alt=\"Logo société\">")
        #expect(out.text == "Bonjour\n\n[Logo société]")
    }

    @Test func htmlCasseNePlantePas() {
        for h in ["<", "<<<>>>", "<a href=\"", "<div><p>fermé jamais", "</p></p></div>", "&", "&#99999999999;", "<!-- sans fin", String(repeating: "<div>", count: 5000)] {
            _ = HTMLText.convert(h)
            _ = HTMLSanitizer.sanitize(h)
        }
    }
}

@Suite("HTMLSanitizer")
struct SanitizerTests {
    @Test func retireScriptsEvenementsEtFrames() {
        let s = HTMLSanitizer.sanitize("<p onclick=\"x()\" onmouseover=\"y()\">a</p><script>alert(1)</script><iframe src=\"https://e.example\"></iframe><object data=\"x\"></object><svg onload=\"z()\"><p>caché</p></svg><form action=\"https://e.example\"><input name=\"pw\">texte</form>")
        let h = s.html.lowercased()
        #expect(!h.contains("onclick") && !h.contains("onmouseover") && !h.contains("onload"))
        #expect(!h.contains("<script") && !h.contains("<iframe") && !h.contains("<object") && !h.contains("<svg") && !h.contains("<form") && !h.contains("<input"))
        #expect(!h.contains("alert(1)"))
        #expect(!h.contains("caché"))  // contenu d'un svg retiré avec lui
        #expect(h.contains("texte"))   // contenu d'un formulaire conservé (texte seulement)
    }

    @Test func imagesDistantesBloqueesEtCompteesPixelsAPart() {
        let s = HTMLSanitizer.sanitize("<img src=\"https://cdn.example/a.png\"><img src=\"//cdn.example/b.png\"><img src=\"https://t.example/p.gif\" width=\"1\" height=\"1\"><img style=\"display:none\" src=\"https://t.example/q.gif\">")
        #expect(s.blockedRemote == 2)
        #expect(s.trackingPixels == 2)
        #expect(!s.html.contains("cdn.example") && !s.html.contains("t.example"))
    }

    @Test func imageIntegreeCidDevientDataURI() {
        let image = InlineImage(mime: "image/png", data: [1, 2, 3])
        let s = HTMLSanitizer.sanitize("<img src=\"cid:a@b\"><img src=\"cid:inconnu\">", inlineImages: ["a@b": image])
        #expect(s.html.contains("src=\"data:image/png;base64,AQID\""))
        #expect(s.html.components(separatedBy: "<img").count == 2)  // l'image au cid inconnu est retirée
    }

    @Test func imageSvgIntegreeRefusee() {
        let image = InlineImage(mime: "image/svg+xml", data: Array("<svg onload=alert(1)>".utf8))
        let s = HTMLSanitizer.sanitize("<img src=\"cid:s\">", inlineImages: ["s": image])
        #expect(!s.html.contains("data:image/svg"))
    }

    @Test func liensDangereuxNeutralises() {
        let s = HTMLSanitizer.sanitize("<a href=\"javascript:alert(1)\">a</a><a href=\" JaVa\tScRiPt:x\">b</a><a href=\"data:text/html,x\">c</a><a href=\"https://ok.example/x?a=1&b=2\">d</a><a href=\"mailto:x@y.fr\">e</a>")
        #expect(!s.html.lowercased().contains("javascript"))
        #expect(!s.html.contains("data:text/html"))
        #expect(s.html.contains("href=\"https://ok.example/x?a=1&amp;b=2\" rel=\"noopener noreferrer\""))
        #expect(s.html.contains("href=\"mailto:x@y.fr\""))
    }

    @Test func styleSansChargementNiSuperposition() {
        let s = HTMLSanitizer.sanitize("<p style=\"color:red;background:url(https://e.example/x.png);position:fixed;top:0\">a</p><style>@import url(https://e.example/a.css);p{background:url(//e.example/b.png);color:blue}</style>")
        #expect(!s.html.contains("e.example"))
        #expect(!s.html.lowercased().contains("position:fixed"))
        #expect(s.html.contains("color:red"))
        #expect(s.html.contains("color:blue"))
    }

    @Test func enveloppeProtegee() {
        let s = HTMLSanitizer.sanitize("<p>x</p>")
        #expect(s.html.contains("Content-Security-Policy"))
        #expect(s.html.contains("default-src 'none'"))
        #expect(HTMLSanitizer.wrapPlain("<b>pas du html</b>").contains("&lt;b&gt;pas du html&lt;/b&gt;"))
    }

    @Test func fermetureDeStylePiegee() {
        let s = HTMLSanitizer.sanitize("<style>p{color:red}</style><script>x</script><p>ok</p>")
        #expect(!s.html.contains("<script"))
        let trick = HTMLSanitizer.sanitize("<style>a{}</scr</style><img src=x onerror=alert(1)>")
        #expect(!trick.html.lowercased().contains("onerror"))
    }
}
