import AppKit
import CoreText
import SwiftUI

/// Draws icon-font glyphs using their ink bounds. Nerd Font glyphs commonly
/// extend well beyond their nominal advance, which causes SwiftUI `Text` to
/// clip them even when the surrounding tab has ample padding.
struct CustomTabIconView: NSViewRepresentable {
    let icon: String
    let fontName: String?
    let isSelected: Bool

    func makeNSView(context: Context) -> CustomTabGlyphView {
        CustomTabGlyphView()
    }

    func updateNSView(_ view: CustomTabGlyphView, context: Context) {
        view.update(icon: icon, fontName: fontName, isSelected: isSelected)
    }
}

final class CustomTabGlyphView: NSView {
    private var icon = ""
    private var font = NSFont.systemFont(ofSize: 11)
    private var color = NSColor.secondaryLabelColor

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let rect = inkBounds
        return NSSize(width: ceil(max(1, rect.width)), height: ceil(max(1, rect.height)))
    }

    func update(icon: String, fontName: String?, isSelected: Bool) {
        let nextFont = fontName.flatMap { NSFont(name: $0, size: 11) } ?? .systemFont(ofSize: 11)
        let nextColor: NSColor = isSelected ? .labelColor : .secondaryLabelColor
        guard self.icon != icon || font != nextFont || color != nextColor else { return }

        self.icon = icon
        font = nextFont
        color = nextColor
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = inkBounds
        let origin = NSPoint(
            x: floor((bounds.width - rect.width) / 2 - rect.minX),
            y: floor((bounds.height - rect.height) / 2 - rect.minY)
        )
        (icon as NSString).draw(at: origin, withAttributes: attributes)
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    private var inkBounds: NSRect {
        (icon as NSString).boundingRect(
            with: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesDeviceMetrics],
            attributes: attributes
        )
    }
}

enum CustomTabIconFont {
    static let name: String? = resolveName()

    private static func resolveName() -> String? {
        let knownNames = [
            "SymbolsNerdFontMono-Regular",
            "CaskaydiaCoveNF-Regular",
            "JetBrainsMonoNerdFont-Regular",
            "Symbols Nerd Font Mono",
            "CaskaydiaCove Nerd Font",
            "JetBrainsMono Nerd Font",
        ]
        if let available = knownNames.first(where: { NSFont(name: $0, size: 11) != nil }) {
            return available
        }

        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let fontsDirectory = library.appendingPathComponent("Fonts", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let nerdFonts = urls
            .filter { url in
                let name = url.lastPathComponent.lowercased()
                return name.contains("nerdfont") || name.contains("nerd font")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for url in nerdFonts {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
                continue
            }
            for descriptor in descriptors {
                guard let fontName = CTFontDescriptorCopyAttribute(
                    descriptor,
                    kCTFontNameAttribute
                ) as? String else { continue }
                if NSFont(name: fontName, size: 11) != nil {
                    return fontName
                }
            }
        }

        return nil
    }
}
