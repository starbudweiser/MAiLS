import AppKit
import SwiftUI
import WebKit

/// Affichage « original » d'un message : HTML déjà nettoyé par `HTMLSanitizer`, dans une vue web **sans JavaScript**, sans stockage,
/// avec **tout chargement distant bloqué** (règle de contenu WebKit) en plus de la politique CSP du document. Les liens ne s'ouvrent
/// qu'après confirmation, adresse réelle affichée.
struct OriginalWebView: NSViewRepresentable {
    let html: String
    /// Appelé si l'affichage sûr est impossible (règle de blocage refusée par WebKit) : on n'affiche alors rien d'autre qu'un message.
    var onFailure: @MainActor (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.web = web
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.onFailure = onFailure
        context.coordinator.show(html)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        var onFailure: @MainActor (String) -> Void = { _ in }
        private var pendingHTML: String?
        private var shownHTML: String?
        private var ruleListReady = false
        private var compiling = false

        /// Le moteur de règles de WebKit n'accepte pas les alternatives `(a|b)` dans les expressions : une règle par schéma.
        private static let rules = """
            [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^//"},"action":{"type":"block"}}]
            """

        func show(_ html: String) {
            guard html != shownHTML else { return }
            pendingHTML = html
            guard ruleListReady else { compileRules(); return }
            load()
        }

        private func load() {
            guard let web, let html = pendingHTML else { return }
            pendingHTML = nil
            shownHTML = html
            web.loadHTMLString(html, baseURL: nil)
        }

        /// Rien ne se charge avant que la règle de blocage soit en place.
        private func compileRules() {
            guard !compiling else { return }
            compiling = true
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "mails-no-remote", encodedContentRuleList: Self.rules) { [weak self] list, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.compiling = false
                    if list == nil { self.onFailure(error.map { String(describing: $0) } ?? L("err.blockrule")) }
                    if let list { self.web?.configuration.userContentController.add(list) }
                    self.ruleListReady = list != nil  // sans règle de blocage, on n'affiche rien
                    if self.ruleListReady { self.load() }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                confirmAndOpen(url)
                return .cancel
            }
            // Seul le document injecté peut se charger.
            if navigationAction.request.url?.absoluteString == "about:blank" || navigationAction.navigationType == .other { return .allow }
            return .cancel
        }

        private func confirmAndOpen(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return }
            let alert = NSAlert()
            alert.messageText = L("reader.openLink.title")
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: L("reader.openLink.open"))
            alert.addButton(withTitle: L("reader.openLink.cancel"))
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }
}
