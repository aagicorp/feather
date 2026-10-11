import AppKit

/// The sidebar, the editor and the terminal panel sit in the window as VS Code lays them out: each a rounded panel standing a
/// little off the panes around it, so the window's chrome (Liquid Glass on macOS 26) shows in the gaps, and the
/// panel itself translucent over that glass like the sidebar. `content` fills the panel.
final class FloatingPanelController: NSViewController {
    static let cornerRadius: CGFloat = 10
    let content: NSViewController
    let panel = NSView()
    /// Which of the theme's colours the panel is: the editor's background, or the chrome for the sidebar.
    let surface: KeyPath<Theme, NSColor>
    private var top: NSLayoutConstraint!, leading: NSLayoutConstraint!, trailing: NSLayoutConstraint!, bottom: NSLayoutConstraint!

    init(content: NSViewController, surface: KeyPath<Theme, NSColor> = \.background) {
        self.content = content
        self.surface = surface
        super.init(nibName: nil, bundle: nil)
        addChild(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        panel.wantsLayer = true
        panel.layer?.cornerRadius = FloatingPanelController.cornerRadius
        panel.layer?.cornerCurve = .continuous
        panel.layer?.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content.view)
        top = panel.topAnchor.constraint(equalTo: view.topAnchor)
        leading = panel.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        trailing = panel.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        bottom = panel.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            top, leading, trailing, bottom,
            content.view.topAnchor.constraint(equalTo: panel.topAnchor),
            content.view.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            content.view.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        applyTheme(Settings.shared.theme)
    }

    /// How far the panel stands off each edge. A side that faces a split divider has none: the divider is the gap.
    func setInsets(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        _ = view
        self.top.constant = top
        self.leading.constant = leading
        self.bottom.constant = -bottom
        self.trailing.constant = -trailing
    }

    var insetsForTests: NSEdgeInsets { NSEdgeInsets(top: top.constant, left: leading.constant, bottom: -bottom.constant, right: -trailing.constant) }

    /// The panel's colour: the theme's background, translucent over glass so the desktop shows through it as
    /// through the sidebar; the plain colour without glass.
    func applyTheme(_ theme: Theme) {
        panel.layer?.backgroundColor = Glass.surface(theme[keyPath: surface]).cgColor
    }
}

/// A split whose divider is the gap between two floating panels: as wide as the gap, drawn as nothing (the
/// window's backdrop shows through), and draggable across its whole width.
final class GapSplitView: NSSplitView {
    static let gap: CGFloat = 6
    override var dividerThickness: CGFloat { GapSplitView.gap }
    override func drawDivider(in rect: NSRect) {}
}
