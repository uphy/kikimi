import AppKit

// MARK: - MarkdownWebViewTheme

/// Resolves the CSS custom properties the page renders with
/// (`docs/design/39-webview-markdown.md` MD13 / §3.4).
///
/// Colors are taken from the same semantic `NSColor`s the rest of the UI uses, so the rendered
/// Markdown tracks light/dark and the user's accent color without the web layer knowing anything
/// about appearance. There is deliberately no background variable: the web view is transparent and
/// the panel paints behind it (§3.2), which is what `Theme.summary` achieved by stripping GitHub's
/// opaque `BackgroundColor`.
enum MarkdownWebViewTheme {
    /// Matches `Theme.summary`'s `FontSize(13)` — the size every other Session Window tab renders
    /// its primary text at.
    static let baseFontSize = 13

    static func cssVariables(for appearance: NSAppearance) -> [String: String] {
        var variables: [String: String] = [:]
        // `NSColor` resolution depends on the *current* drawing appearance, not on the color's own
        // state; without this the dynamic colors below resolve against whatever appearance happens
        // to be current on the main thread.
        appearance.performAsCurrentDrawingAppearance {
            variables = [
                "--kikimi-fg": css(.labelColor),
                "--kikimi-fg-secondary": css(.secondaryLabelColor),
                "--kikimi-accent": css(.controlAccentColor),
                // Semi-transparent on purpose: code blocks sit on the panel's material, and an
                // opaque fill would read as a second window pasted on top.
                "--kikimi-code-bg": css(.labelColor, alpha: 0.08),
                "--kikimi-border": css(.separatorColor),
                "--kikimi-font-size": "\(baseFontSize)px",
                "--kikimi-font-family": "-apple-system, BlinkMacSystemFont, sans-serif",
                // Not a color: mermaid picks a whole palette by name rather than by CSS variable
                // (§4), so the page needs to know which appearance it is in. `theme.ts` mirrors
                // this onto `data-appearance`.
                "--kikimi-appearance": isDark(appearance) ? "dark" : "light"
            ]
        }
        return variables
    }

    /// Covers the accessibility variants (`darkAqua`, `accessibilityHighContrastDarkAqua`) as well
    /// as plain dark mode, so a high-contrast user does not get mermaid's light palette.
    static func isDark(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua
    }

    /// `rgba(...)` rather than a hex string so the alpha override above survives the conversion.
    /// Falls back to the unconverted color's components if the color space conversion fails (it
    /// does not for the catalog colors used here, but the API is optional).
    private static func css(_ color: NSColor, alpha: CGFloat? = nil) -> String {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let red = Int((resolved.redComponent * 255).rounded())
        let green = Int((resolved.greenComponent * 255).rounded())
        let blue = Int((resolved.blueComponent * 255).rounded())
        let effectiveAlpha = alpha ?? resolved.alphaComponent
        return "rgba(\(red), \(green), \(blue), \(String(format: "%.3f", effectiveAlpha)))"
    }
}
