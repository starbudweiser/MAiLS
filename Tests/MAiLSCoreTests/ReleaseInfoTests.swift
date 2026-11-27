import Foundation
import Testing

@testable import MAiLSCore

@Suite("Mise à jour : release et versions")
struct ReleaseInfoTests {
    private func json(tag: String = "v0.1.4", draft: Bool = false, pre: Bool = false, assets: String) -> Data {
        Data(#"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(pre),"assets":[\#(assets)]}"#.utf8)
    }
    private let zip = #"{"name":"MAiLS-0.1.4.zip","browser_download_url":"https://github.com/starbudweiser/MAiLS/releases/download/v0.1.4/MAiLS-0.1.4.zip"}"#

    @Test func lectureDUneRelease() {
        let info = ReleaseInfo.parse(json(assets: #"{"name":"MAiLS-0.1.4.zip.sha256","browser_download_url":"https://github.com/x/y.sha256"},"# + zip))
        #expect(info?.version == "0.1.4")
        #expect(info?.assetURL.lastPathComponent == "MAiLS-0.1.4.zip")
    }

    @Test func releasesRefusees() {
        #expect(ReleaseInfo.parse(json(assets: "")) == nil)                                   // aucun .zip
        #expect(ReleaseInfo.parse(json(draft: true, assets: zip)) == nil)
        #expect(ReleaseInfo.parse(json(pre: true, assets: zip)) == nil)
        let ailleurs = #"{"name":"a.zip","browser_download_url":"https://evil.example/a.zip"}"#
        #expect(ReleaseInfo.parse(json(assets: ailleurs)) == nil)                             // seulement github.com en https
        #expect(ReleaseInfo.parse(Data("pas du json".utf8)) == nil)
    }

    @Test func comparaisonDesVersions() {
        #expect(ReleaseInfo.isNewer("0.1.4", than: "0.1.3"))
        #expect(ReleaseInfo.isNewer("v0.1.10", than: "0.1.9"))
        #expect(ReleaseInfo.isNewer("0.2", than: "0.1.9"))
        #expect(!ReleaseInfo.isNewer("0.1.3", than: "0.1.3"))
        #expect(!ReleaseInfo.isNewer("0.1", than: "0.1.0"))
        #expect(!ReleaseInfo.isNewer("0.1.2", than: "0.1.3"))
    }
}
