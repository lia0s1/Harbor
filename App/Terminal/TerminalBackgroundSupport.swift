import AppKit
import SwiftUI
import HarborKit
import SwiftTerm

/// AppKit / SwiftUI bridges for HarborKit's pure `TerminalBackground` data, plus
/// the storage key the terminal and Settings both observe.
extension TerminalBackground.RGBA {
    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }

    var swiftUIColor: SwiftUI.Color {
        SwiftUI.Color(nsColor: nsColor)
    }

    /// Build from a SwiftUI/AppKit color (e.g. from a ColorPicker), converted to
    /// sRGB and quantized to 8-bit components.
    init(nsColor: NSColor) {
        let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
        func byte(_ v: CGFloat) -> UInt8 { UInt8((v * 255).rounded().clamped(0, 255)) }
        self.init(
            red: byte(srgb.redComponent),
            green: byte(srgb.greenComponent),
            blue: byte(srgb.blueComponent),
            alpha: byte(srgb.alphaComponent)
        )
    }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(self, lo), hi) }
}

/// Where the terminal-background customization JSON is persisted. The terminal
/// (`TerminalHostingView`) and Settings observe this same `@AppStorage` key so
/// edits apply live to every open session, exactly like the theme/font do.
enum TerminalBackgroundPreference {
    static let storageKey = "terminalBackground"

    /// Decode the stored JSON, falling back to the theme default.
    static func load() -> TerminalBackground {
        TerminalBackground.decoded(from: UserDefaults.standard.string(forKey: storageKey))
    }
}

// MARK: - Container view

/// The stable NSView that wraps a session's terminal and, when a custom
/// background image is configured, an image layer BEHIND the terminal.
///
/// Layout:
///   self
///   ├─ imageView   (NSImageView, resizeAspectFill, alpha = clamped opacity)   ← only in image mode
///   └─ terminal    (made translucent in image mode so the image shows through)
///
/// In `.theme` / `.color` modes the image view is removed and the terminal
/// paints its own opaque `nativeBackgroundColor`.
final class TerminalContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayerBacking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayerBacking()
    }

    /// GPU-composite the container and its children (the background-image layer
    /// and the terminal, which SwiftTerm already layer-backs). The container has
    /// no `draw(_:)`, so `.onSetNeedsDisplay` stops AppKit doing software redraw
    /// passes on resize — its empty backing store never goes stale; it purely
    /// composites its subviews on the GPU via Core Animation.
    private func configureLayerBacking() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    /// Lazily created; only present while a background image is shown.
    private var imageView: NSImageView?

    /// Decoded image cache keyed by path, so a re-apply that did NOT change the
    /// image (e.g. a live text-color drag, which fires apply() per tick) reuses
    /// the decoded `NSImage` instead of re-reading the file from disk each time.
    private var cachedImagePath: String?
    private var cachedImage: NSImage?

    /// Reparent the terminal into this container (or re-add after a reconnect
    /// swapped in a fresh view), keeping it ABOVE any image layer.
    func embed(_ terminal: LocalProcessTerminalView) {
        guard terminal.superview !== self else { return }
        // Drop any stale terminal subview without disturbing the image view.
        for sub in subviews where sub is LocalProcessTerminalView && sub !== terminal {
            sub.removeFromSuperview()
        }
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal) // appended last → topmost, above the image view
    }

    /// Keep the terminal as the topmost subview after the image layer is added.
    fileprivate func raiseTerminalAboveImage() {
        guard let terminal = subviews.first(where: { $0 is LocalProcessTerminalView }),
              subviews.last !== terminal else { return }
        terminal.removeFromSuperview()
        addSubview(terminal)
    }

    /// Apply a resolved background to this container + its terminal. Idempotent
    /// callers gate on change; this method just builds the requested state.
    func apply(background: TerminalBackground, theme: TerminalTheme, terminal: LocalProcessTerminalView) {
        // Resolve image-mode only if the file still exists; a missing/deleted
        // path falls back to the theme background (no crash, no blank screen).
        let image: NSImage? = background.wantsImage ? loadImage(at: background.imagePath) : nil

        if background.mode == .image, let image {
            // The container itself becomes the OPAQUE base, painted with the
            // theme background. The image view above it draws at the clamped
            // opacity, so the effective backdrop = theme color blended with the
            // image — the picture can never fully wash out, keeping glyphs
            // readable. The terminal on top is made fully transparent.
            wantsLayer = true
            layer?.backgroundColor = theme.background.nsColor.cgColor
            installImage(image, opacity: background.imageOpacity, blur: background.imageBlur)
            // SwiftTerm's `nativeBackgroundColor` only repaints cell/region fills;
            // it does NOT touch the view's own layer (that's set once at setup).
            // So make BOTH transparent: clear cell fills via nativeBackgroundColor
            // AND clear the view's layer so the image behind shows through.
            terminal.nativeBackgroundColor = .clear
            // Honor a custom text color over the image too; else theme default.
            terminal.nativeForegroundColor = background.foreground?.nsColor ?? theme.foreground.nsColor
            terminal.wantsLayer = true
            terminal.layer?.isOpaque = false
            terminal.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            // No image: remove the layer and paint an opaque terminal background.
            removeImage()
            layer?.backgroundColor = nil
            let bg: NSColor
            switch background.mode {
            case .color:
                bg = background.color.nsColor
            case .theme, .image:
                // .image with a missing file falls back to the theme bg here.
                bg = theme.background.nsColor
            }
            // The custom text color applies in EVERY mode (theme / color /
            // image), independent of the background, so users can recolor text
            // over any backdrop. Falls back to the theme's foreground when unset.
            let fg = background.foreground?.nsColor ?? theme.foreground.nsColor
            terminal.nativeBackgroundColor = bg
            // Always set the foreground explicitly so switching back from a
            // custom text color reverts cleanly to the theme's foreground.
            terminal.nativeForegroundColor = fg
            // Restore the terminal's own opaque layer (it may have been cleared
            // by a previous image-mode pass; SwiftTerm won't reset it itself).
            terminal.wantsLayer = true
            terminal.layer?.isOpaque = true
            terminal.layer?.backgroundColor = bg.cgColor
        }
    }

    // MARK: - Image layer

    private func installImage(_ image: NSImage, opacity: Double, blur: Double) {
        let view: NSImageView
        if let existing = imageView {
            view = existing
        } else {
            view = NSImageView()
            view.imageScaling = .scaleAxesIndependently
            view.imageAlignment = .alignCenter
            view.wantsLayer = true
            view.layer?.contentsGravity = .resizeAspectFill
            view.layer?.masksToBounds = true
            view.autoresizingMask = [.width, .height]
            view.frame = bounds
            // Insert below the terminal so the terminal stays on top.
            let terminal = subviews.first { $0 is LocalProcessTerminalView }
            addSubview(view, positioned: .below, relativeTo: terminal)
            imageView = view
        }
        view.image = image
        view.alphaValue = CGFloat(opacity)
        applyBlur(blur, to: view)
        raiseTerminalAboveImage()
    }

    private func applyBlur(_ radius: Double, to view: NSImageView) {
        if radius <= 0 {
            view.contentFilters = []
            return
        }
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(radius, forKey: kCIInputRadiusKey)
        view.contentFilters = filter.map { [$0] } ?? []
        // Clamp so the blur doesn't reveal transparent edges around the image.
        view.layer?.masksToBounds = true
    }

    private func removeImage() {
        imageView?.removeFromSuperview()
        imageView = nil
    }

    /// Load an image from a path, returning nil if the file is missing or not a
    /// decodable image (e.g. it was deleted after being chosen). Reuses the last
    /// decoded image when the path is unchanged so repeated applies (a live
    /// color drag) don't hit the disk every tick.
    private func loadImage(at path: String) -> NSImage? {
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            cachedImagePath = nil
            cachedImage = nil
            return nil
        }
        if path == cachedImagePath, let cachedImage { return cachedImage }
        let image = NSImage(contentsOfFile: path)
        cachedImagePath = image == nil ? nil : path
        cachedImage = image
        return image
    }
}
