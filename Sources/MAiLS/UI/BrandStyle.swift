// MODÈLE (Socle) : coloration de la lettre minuscule du nom de l'appli dans les textes AppKit — tirée de mDESK (Sources/mDESK/Brand+AppKit.swift).
import AppKit
import SwiftUI

enum BrandStyle {
    /// Couleur du logo de MAiLS (voir `Brand.logoColor`).
    static let color = NSColor(Brand.logoColor)

    /// Texte dont la lettre minuscule de chaque occurrence du nom est colorée ; le reste garde ses attributs.
    static func colored(_ base: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: base)
        for range in Brand.lowercaseRanges(in: base.string) {
            out.addAttribute(.foregroundColor, value: color, range: range)
        }
        return out
    }

    static func colored(_ text: String, font: NSFont) -> NSAttributedString {
        colored(NSAttributedString(string: text, attributes: [.font: font]))
    }

    /// Colore le nom dans tous les textes d'une fenêtre (dialogues compris).
    @MainActor
    static func apply(to window: NSWindow) {
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.isEditable, field.stringValue.contains(Brand.name) {
                field.attributedStringValue = colored(field.attributedStringValue)
            }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
    }
}
