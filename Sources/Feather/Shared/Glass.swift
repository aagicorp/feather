import AppKit

/// Liquid Glass for what floats over the window: Quick Open, the Command Palette, suggestions, notice cards,
/// the merge-conflict buttons. On macOS 26 these sit on `NSGlassEffectView`, tinted toward the theme's chrome
/// so the theme still reads through; on earlier systems, and when Reduce Transparency is on, the same views
/// are a flat panel of the chrome colour, as before. Windows and panes themselves stay as they are: glass is
/// for the layer above the content, which is where the system puts it.
enum Glass {
    /// Whether glass is drawn right now: the system has it, the person has not asked for less transparency, and
    /// the Preferences switch is on.
    static var isActive: Bool {
        if #available(macOS 26, *) { return isBuiltWithGlass && Settings.shared.glassChrome && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
        return false
    }

    /// `NSGlassEffectView` is in the macOS 26 SDK (Xcode 26). An older toolchain builds Feather without glass:
    /// the same flat panels as on earlier systems, and `isActive` stays false. `swift build -Xswiftc
    /// -DFEATHER_NO_GLASS` builds that way on purpose, to check it on a Mac that has the newer SDK.
    #if compiler(>=6.2) && !FEATHER_NO_GLASS
    static let isBuiltWithGlass = true
    #else
    static let isBuiltWithGlass = false
    #endif

    /// How much of the theme colour lies over the window chrome's glass: the theme still reads, the desktop
    /// shows through blurred, as it does behind the system's own sidebars. `defaults write com.aagicorp.feather
    /// glassChromeAlpha 0.4` tunes it; 1 is the flat theme colour.
    static var chromeAlpha: CGFloat {
        let stored = UserDefaults.standard.object(forKey: "glassChromeAlpha") as? Double
        return CGFloat(min(1, max(0, stored ?? 0.55)))
    }

    /// The chrome colour as it is painted over a backdrop: translucent with glass, opaque without.
    static func chrome(_ color: NSColor) -> NSColor { isActive ? color.withAlphaComponent(chromeAlpha) : color }

    /// How much of the theme's background colour lies over the glass in the editor and terminal panels: more than
    /// the chrome, since text is read against it. `defaults write com.aagicorp.feather glassSurfaceAlpha 0.7`
    /// tunes it; 1 is the flat colour.
    static var surfaceAlpha: CGFloat {
        let stored = UserDefaults.standard.object(forKey: "glassSurfaceAlpha") as? Double
        return CGFloat(min(1, max(0, stored ?? 0.82)))
    }

    /// A panel's background as painted over the window's glass: translucent with glass, opaque without.
    static func surface(_ color: NSColor) -> NSColor { isActive ? color.withAlphaComponent(surfaceAlpha) : color }

    /// A pane inside the sidebar paints nothing of its own with glass, so the sidebar's backdrop shows; without
    /// glass it paints the chrome colour as before.
    static func paneBackground(_ color: NSColor) -> CGColor { isActive ? NSColor.clear.cgColor : color.cgColor }

    /// The ground under a bar or pane of the window chrome: the system's sidebar or title-bar material, which is
    /// Liquid Glass on macOS 26, with the theme colour over it. Without glass it is the plain colour. Fills its
    /// superview and keeps to the back; `tint` changes the colour with the theme or the project colour.
    final class Backdrop: NSView {
        private let effect = NSVisualEffectView()
        private let tintView = NSView()
        private var base = Settings.shared.theme.chrome

        init(material: NSVisualEffectView.Material) {
            super.init(frame: .zero)
            effect.material = material
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            tintView.wantsLayer = true
            for view in [effect, tintView] {
                view.autoresizingMask = [.width, .height]
                addSubview(view)
            }
            autoresizingMask = [.width, .height]
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: Settings.didChange, object: nil)
            refresh()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        deinit { NotificationCenter.default.removeObserver(self) }

        func tint(_ color: NSColor) {
            base = color
            refresh()
        }

        @objc private func refresh() {
            effect.isHidden = !Glass.isActive
            tintView.layer?.backgroundColor = Glass.chrome(base).cgColor
        }

        override func layout() {
            super.layout()
            effect.frame = bounds
            tintView.frame = bounds
        }

        var isGlassForTests: Bool { !effect.isHidden }
        var tintColorForTests: NSColor? { tintView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) }
    }

    /// Puts a backdrop at the back of `view`, filling it.
    @discardableResult
    static func backdrop(_ material: NSVisualEffectView.Material, in view: NSView) -> Backdrop {
        let backdrop = Backdrop(material: material)
        backdrop.frame = view.bounds
        view.addSubview(backdrop, positioned: .below, relativeTo: nil)
        return backdrop
    }

    /// A surface for `content`: glass with rounded corners, or a flat panel. `content` fills it.
    static func panel(around content: NSView, cornerRadius: CGFloat, tint: NSColor) -> NSView {
        #if compiler(>=6.2) && !FEATHER_NO_GLASS
        if #available(macOS 26, *), isActive {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint.withAlphaComponent(Glass.tintAlpha)
            glass.contentView = content
            return glass
        }
        #endif
        let flat = FlatPanel()
        flat.wantsLayer = true
        flat.layer?.cornerRadius = cornerRadius
        flat.layer?.masksToBounds = true
        flat.layer?.backgroundColor = tint.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        flat.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: flat.leadingAnchor), content.trailingAnchor.constraint(equalTo: flat.trailingAnchor),
            content.topAnchor.constraint(equalTo: flat.topAnchor), content.bottomAnchor.constraint(equalTo: flat.bottomAnchor),
        ])
        return flat
    }

    /// The theme changed: the surface takes the new colour.
    static func retint(_ surface: NSView, _ tint: NSColor) {
        #if compiler(>=6.2) && !FEATHER_NO_GLASS
        if #available(macOS 26, *), let glass = surface as? NSGlassEffectView {
            glass.tintColor = tint.withAlphaComponent(Glass.tintAlpha)
            return
        }
        #endif
        surface.layer?.backgroundColor = tint.cgColor
    }

    /// How much of the theme colour shows in the glass: enough to tell the themes apart, little enough to see through.
    static let tintAlpha: CGFloat = 0.55

    /// A plain panel, told apart from any other view so tests can check which surface was made.
    final class FlatPanel: NSView {}
}
