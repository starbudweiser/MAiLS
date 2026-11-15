import AppKit
import MAiLSCore
import SwiftUI

struct ReaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.reader {
            case .none:
                centered(L("reader.select"))
            case .loading:
                centered(L("reader.loading"))
            case .failed(let message):
                centered(L("reader.error", message), color: Socle.C.danger)
            case .ready(let message, let summary):
                MessageContent(message: message, summary: summary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Socle.C.bg)
    }

    private func centered(_ text: String, color: Color = Socle.C.textSubtle) -> some View {
        Text(text).socle(Socle.T.body).foregroundStyle(color).multilineTextAlignment(.center).padding(Socle.M.space6)
    }
}

private struct MessageContent: View {
    @Environment(AppModel.self) private var model
    let message: ReadableMessage
    let summary: MessageSummary
    @State private var webFailure: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Socle.C.border).frame(height: 1)
            if model.readerMode == .original {
                if let failure = webFailure {
                    Text(L("reader.error", failure)).socle(Socle.T.body).foregroundStyle(Socle.C.danger).padding(Socle.M.space6)
                    Spacer()
                } else {
                    OriginalWebView(html: message.originalHTML) { webFailure = $0 }
                }
            } else {
                readingBody
            }
        }
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            Text(subject).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong).textSelection(.enabled)
            VStack(alignment: .leading, spacing: Socle.M.space1) {
                if let from = message.headers.from { addressLine(L("reader.from"), [from]) }
                if !message.headers.to.isEmpty { addressLine(L("reader.to"), message.headers.to) }
                if !message.headers.cc.isEmpty { addressLine(L("reader.cc"), message.headers.cc) }
            }
            HStack(spacing: Socle.M.space3) {
                Text(dateText).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                Spacer()
                SocleSegmented(
                    options: [AppModel.ReaderMode.reading, .original], selection: model.readerMode,
                    label: { $0 == .reading ? L("reader.mode.reading") : L("reader.mode.original") },
                    tone: { _ in .neutral }, onSelect: { model.readerMode = $0 })
            }
            notices
        }
        .padding(Socle.M.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Socle.C.surface)
    }

    private var subject: String {
        message.headers.subject.isEmpty ? L("reader.noSubject") : message.headers.subject
    }

    private var dateText: String {
        let epoch = message.headers.sentAt ?? summary.sentAt
        return Date(timeIntervalSince1970: TimeInterval(epoch)).formatted(date: .complete, time: .shortened)
    }

    private func addressLine(_ label: String, _ addresses: [MailAddress]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Socle.M.space2) {
            Text(label).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).frame(width: 28, alignment: .leading)
            Text(addresses.map { address in address.name.map { "\($0) <\(address.email)>" } ?? address.email }.joined(separator: ", "))
                .socle(Socle.T.body).foregroundStyle(Socle.C.text).textSelection(.enabled).lineLimit(3)
        }
    }

    @ViewBuilder private var notices: some View {
        let blocked = message.blockedRemoteCount
        let trackers = message.trackingPixelCount
        if blocked > 0 || trackers > 0 || message.truncated {
            VStack(alignment: .leading, spacing: Socle.M.space1) {
                if blocked > 0 { notice("photo.badge.exclamationmark", L("reader.blocked", blocked)) }
                if trackers > 0 { notice("eye.slash", L("reader.trackers", trackers)) }
                if message.truncated { notice("exclamationmark.triangle", L("reader.truncated")) }
            }
        }
    }

    private func notice(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: Socle.M.space1_5) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(text)
        }
        .socle(Socle.T.meta)
        .foregroundStyle(Socle.C.textMuted)
    }

    // MARK: Mode lecture

    private var readingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Socle.M.space6) {
                Text(message.readingText.isEmpty ? L("reader.noText") : message.readingText)
                    .socle(Socle.T.reading)
                    .foregroundStyle(message.readingText.isEmpty ? Socle.C.textSubtle : Socle.C.text)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !message.attachments.isEmpty { attachments }
                if !message.links.isEmpty { links }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(Socle.M.space6)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            Text(L("reader.attachments")).socle(Socle.T.eyebrow).foregroundStyle(Socle.C.textSubtle)
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, a in
                HStack(spacing: Socle.M.space2) {
                    Image(systemName: "paperclip").foregroundStyle(Socle.C.textMuted).accessibilityHidden(true)
                    Text(a.filename).socle(Socle.T.body).foregroundStyle(Socle.C.text).lineLimit(1).truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
                }
            }
        }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            Text(L("reader.links")).socle(Socle.T.eyebrow).foregroundStyle(Socle.C.textSubtle)
            ForEach(Array(message.links.enumerated()), id: \.offset) { _, link in
                Button {
                    if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        if !link.label.isEmpty, link.label != link.url {
                            Text(link.label).socle(Socle.T.body).foregroundStyle(Socle.C.text).lineLimit(1)
                        }
                        // L'adresse réelle est toujours visible : jamais un texte qui en cache une autre.
                        Text(link.url).socle(Socle.T.monoSm).foregroundStyle(Socle.C.accentText).lineLimit(2).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
