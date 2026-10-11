import AppKit
import AVKit
import PDFKit

/// What a tab shows in place of the text editor: rendered Markdown, or a media file.
protocol TabPreview: NSView {
    /// The view that should take keyboard focus while the preview is showing.
    var focusView: NSView { get }
    /// Builds the preview from its source.
    func render()
    /// A settings or theme change. It must not re-read or re-decode anything it does not have to.
    func applyTheme()
}

/// A preview that edits something of its own (an API request, say) and can save it when its tab is closed with
/// unsaved changes; the document store knows nothing about what it holds.
protocol SavableTabPreview: TabPreview {
    /// Saves; false when the person cancelled (a "where to save" sheet, for instance) and the tab must stay open.
    func saveForClosing() -> Bool
}

/// Keeps a picture in the middle of the pane when it is smaller than the pane, at any zoom.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// The picture itself. The decoded image is handed to the view's layer once, so zooming and panning are done by
/// the GPU; nothing is redrawn on the CPU while you pinch. (Redrawing a large bitmap and a checkerboard of
/// thousands of squares at every zoom step is what made the first version of this viewer lag.)
private final class ImageCanvasView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ image: CGImage?) { layer?.contents = image }

    /// A two-tone checkerboard behind the pixels, as a single repeating tile rather than drawn squares.
    func setCheckerboard(dark: Bool) {
        let (a, b): (NSColor, NSColor) = dark ? (NSColor(hex: 0x262626), NSColor(hex: 0x303030)) : (NSColor(hex: 0xFFFFFF), NSColor(hex: 0xE9E9E9))
        let tile = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            a.setFill(); rect.fill()
            b.setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        layer?.backgroundColor = NSColor(patternImage: tile).cgColor
    }

    /// Sharp pixels when zoomed far in (you can count them); smooth scaling otherwise.
    func setZoom(_ magnification: CGFloat, isVector: Bool) {
        layer?.magnificationFilter = (!isVector && magnification >= 3) ? .nearest : .linear
    }
}

/// A scroll view that also zooms with ⌘-scroll (around the pointer) and double-tap (fit ↔ actual size).
private final class ZoomScrollView: NSScrollView {
    var onZoomGesture: (() -> Void)?
    var onSmartMagnify: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) else {
            return super.scrollWheel(with: event)
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
        guard delta != 0, let document = documentView else { return }
        let target = max(minMagnification, min(maxMagnification, magnification * (1 + delta)))
        setMagnification(target, centeredAt: document.convert(event.locationInWindow, from: nil))
        onZoomGesture?()
    }

    override func smartMagnify(with event: NSEvent) { onSmartMagnify?() }
}

/// Shows an image, SVG, PDF, audio or video file. Only viewers that ship with macOS are used.
final class MediaPreviewView: NSView, TabPreview {
    enum Kind { case image, svg, pdf, player }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "ico", "icns"]
    private static let playerExtensions: Set<String> = ["mp4", "mov", "m4v", "mp3", "wav", "m4a", "aac", "aiff", "flac"]
    /// Bigger pictures are decoded down to this, which is already far beyond any screen; it bounds memory use.
    private static let maxDecodedPixels = 8192
    private static let decodeQueue = DispatchQueue(label: "feather.media.decode", qos: .userInitiated)

    static func kind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if ext == "svg" { return .svg }
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if playerExtensions.contains(ext) { return .player }
        return nil
    }

    private let kind: Kind
    private let url: URL
    /// Only for SVG: the picture is drawn from the document's text, so it follows edits made in the source.
    private let document: TextDocument?
    private let scrollView = ZoomScrollView()
    private let canvas = ImageCanvasView(frame: .zero)
    private var animatedView: NSImageView?           // animated GIFs only; a layer's contents cannot animate
    private var vectorImage: NSImage?
    private var rasterizedScale: CGFloat = 0
    private let info = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private let bar = NSView()
    private var player: AVPlayerView?
    private var renderWork: DispatchWorkItem?
    private var sharpenWork: DispatchWorkItem?
    private var loadGeneration = 0
    /// True until the user zooms; while it is, the picture refits whenever the pane changes size.
    private var isFitMode = true
    private var isImageKind: Bool { kind == .image || kind == .svg }

    var focusView: NSView { player ?? scrollView }

    init(url: URL, kind: Kind, document: TextDocument?) {
        self.url = url
        self.kind = kind
        self.document = kind == .svg ? document : nil
        super.init(frame: .zero)
        wantsLayer = true
        buildBar()
        switch kind {
        case .image, .svg: buildImageViewer()
        case .pdf: buildPDFViewer()
        case .player: buildPlayer()
        }
        if let document = self.document {
            NotificationCenter.default.addObserver(self, selector: #selector(sourceChanged),
                                                   name: NSTextStorage.didProcessEditingNotification, object: document.storage)
        }
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        player?.player?.pause()
    }

    // MARK: - Building

    private func pin(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content, positioned: .below, relativeTo: bar)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor), content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor), content.bottomAnchor.constraint(equalTo: bar.topAnchor),
        ])
    }

    private func buildBar() {
        bar.wantsLayer = true
        info.font = .systemFont(ofSize: 11)
        info.lineBreakMode = .byTruncatingMiddle
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let controls = NSStackView()
        controls.spacing = 6
        if isImageKind {
            for (title, tip, action) in [("−", "Zoom out (⌘−)", #selector(zoomOut)), ("+", "Zoom in (⌘+)", #selector(zoomIn)),
                                         ("Fit", "Fit to the pane", #selector(zoomToFit)), ("100%", "Actual size", #selector(zoomActual))] {
                let button = NSButton(title: title, target: self, action: action)
                button.bezelStyle = .recessed
                button.controlSize = .small
                button.toolTip = tip
                controls.addArrangedSubview(button)
            }
            zoomLabel.alignment = .right
            zoomLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true      // fixed, so the buttons do not shift
            controls.addArrangedSubview(zoomLabel)
        }
        for view in [info, controls] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor), bar.heightAnchor.constraint(equalToConstant: 30),
            info.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12), info.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            info.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -12),
            controls.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            controls.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
    }

    private func buildImageViewer() {
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 64
        scrollView.borderType = .noBorder
        scrollView.useFeatherScrollers()
        scrollView.onZoomGesture = { [weak self] in self?.userZoomed() }
        scrollView.onSmartMagnify = { [weak self] in
            guard let self else { return }
            if self.isFitMode { self.zoomActual() } else { self.zoomToFit() }
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(liveMagnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
        clip.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: clip)
        pin(scrollView)
    }

    private func buildPDFViewer() {
        let pdf = PDFView()
        pdf.autoScales = true
        pdf.document = PDFDocument(url: url)
        pin(pdf)
    }

    private func buildPlayer() {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        view.controlsStyle = .inline
        player = view
        pin(view)
    }

    // MARK: - Loading

    @objc private func sourceChanged() {
        guard document?.storage.editedMask.contains(.editedCharacters) == true else { return }
        renderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.render() }
        renderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private var fileDescription: String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return "\(url.pathExtension.uppercased()) · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// Colours only. The picture, PDF or player is left exactly as it is.
    func applyTheme() {
        let theme = Settings.shared.theme
        layer?.backgroundColor = theme.background.cgColor
        bar.layer?.backgroundColor = theme.chrome.cgColor
        info.textColor = theme.lineNumber
        zoomLabel.textColor = theme.lineNumber
        scrollView.backgroundColor = theme.background
        canvas.setCheckerboard(dark: theme.isDark)
    }

    func render() {
        applyTheme()
        switch kind {
        case .svg: renderVector()
        case .image: loadBitmap()
        case .pdf, .player: info.stringValue = fileDescription
        }
    }

    /// Decodes off the main thread, straight to the size that will be shown, so opening a 40-megapixel photo
    /// neither blocks the window nor keeps a full-resolution copy in memory.
    private func loadBitmap() {
        loadGeneration += 1
        let generation = loadGeneration
        let url = self.url
        MediaPreviewView.decodeQueue.async { [weak self] in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                DispatchQueue.main.async { self?.showFailure("This image could not be read.") }
                return
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            var pixels = NSSize(width: properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0,
                                height: properties?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0)
            if let orientation = properties?[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
                pixels = NSSize(width: pixels.height, height: pixels.width)          // stored sideways
            }
            let isAnimated = CGImageSourceGetCount(source) > 1 && url.pathExtension.lowercased() == "gif"
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceShouldCacheImmediately: true,
                                            kCGImageSourceThumbnailMaxPixelSize: MediaPreviewView.maxDecodedPixels]
            let decoded = isAnimated ? nil : CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation else { return }
                if isAnimated, let image = NSImage(contentsOf: url) {
                    self.showAnimated(image, pixels: pixels)
                } else if let decoded {
                    if pixels.width <= 0 { pixels = NSSize(width: decoded.width, height: decoded.height) }
                    self.present(decoded, size: pixels, isVector: false)
                } else {
                    self.showFailure("This image could not be read.")
                }
            }
        }
    }

    private func renderVector() {
        guard let document, let image = NSImage(data: Data(document.text.utf8)), image.size.width > 0, image.size.height > 0 else {
            return showFailure("This SVG could not be drawn — check the source for an error.")
        }
        vectorImage = image
        rasterizedScale = 0
        rasterizeVector(sizeChanged: canvas.frame.size != image.size)
    }

    /// Draws the SVG to a bitmap at the resolution the current zoom needs. It is redone when zooming stops, so the
    /// picture is always crisp without being re-drawn during the gesture.
    private func rasterizeVector(sizeChanged: Bool = false) {
        guard let image = vectorImage else { return }
        let backing = window?.backingScaleFactor ?? 2
        let longest = max(image.size.width, image.size.height)
        let scale = max(1, min(scrollView.magnification * backing, CGFloat(MediaPreviewView.maxDecodedPixels) / 2 / longest))
        guard sizeChanged || rasterizedScale == 0 || scale > rasterizedScale * 1.2 || scale < rasterizedScale / 2.5 else { return }
        let width = Int((image.size.width * scale).rounded()), height = Int((image.size.height * scale).rounded())
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        rasterizedScale = scale
        if let bitmap = rep.cgImage { present(bitmap, size: image.size, isVector: true) }
    }

    private func present(_ image: CGImage, size: NSSize, isVector: Bool) {
        animatedView?.removeFromSuperview()
        animatedView = nil
        let sizeChanged = canvas.frame.size != size
        if sizeChanged { canvas.frame = NSRect(origin: .zero, size: size) }
        canvas.show(image)
        canvas.setZoom(scrollView.magnification, isVector: isVector)
        info.stringValue = "\(Int(size.width)) × \(Int(size.height)) · " + fileDescription
        if sizeChanged { isFitMode = true; needsLayout = true }
        updateZoomLabel()
    }

    private func showAnimated(_ image: NSImage, pixels: NSSize) {
        let size = pixels.width > 0 ? pixels : image.size
        canvas.frame = NSRect(origin: .zero, size: size)
        canvas.show(nil)
        let view = animatedView ?? NSImageView()
        view.imageScaling = .scaleAxesIndependently
        view.animates = true
        view.image = image
        view.frame = canvas.bounds
        view.autoresizingMask = [.width, .height]
        if view.superview == nil { canvas.addSubview(view) }
        animatedView = view
        info.stringValue = "\(Int(size.width)) × \(Int(size.height)) · animated · " + fileDescription
        isFitMode = true
        needsLayout = true
    }

    private func showFailure(_ message: String) {
        canvas.show(nil)
        info.stringValue = message
    }

    override func layout() {
        super.layout()
        // While the user has not chosen a zoom, the picture keeps fitting the pane as the pane changes size.
        if isFitMode, isImageKind, scrollView.contentSize.width > 0, canvas.frame.width > 0 { applyFit() }
    }

    // MARK: - Zoom

    /// Zooms around the middle of what is on screen, so the part being looked at stays put.
    private func setMagnification(_ value: CGFloat) {
        let clamped = max(scrollView.minMagnification, min(scrollView.maxMagnification, value))
        let visible = scrollView.documentVisibleRect.intersection(canvas.bounds)
        let anchor = visible.isEmpty ? NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY) : NSPoint(x: visible.midX, y: visible.midY)
        scrollView.setMagnification(clamped, centeredAt: anchor)
        zoomSettled()
    }

    private func userZoomed() {
        isFitMode = false
        zoomSettled()
    }

    private func zoomSettled() {
        canvas.setZoom(scrollView.magnification, isVector: kind == .svg)
        updateZoomLabel()
        guard kind == .svg else { return }
        sharpenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rasterizeVector() }
        sharpenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    /// Used by the window's ⌘+ / ⌘− when a picture is the active tab.
    func zoom(by factor: CGFloat) {
        guard isImageKind else { return }
        isFitMode = false
        setMagnification(scrollView.magnification * factor)
    }

    @objc private func zoomIn() { zoom(by: 1.25) }

    @objc private func zoomOut() { zoom(by: 1 / 1.25) }

    @objc func zoomActual() {
        isFitMode = false
        setMagnification(1)
    }

    @objc func zoomToFit() {
        isFitMode = true
        applyFit()
    }

    /// Shrinks a large picture to fit the pane. A small one is shown at actual size rather than blown up — except
    /// a small SVG, which is vector and far more useful enlarged.
    private func applyFit() {
        let available = scrollView.contentSize
        guard canvas.frame.width > 0, available.width > 40, available.height > 40 else { return }
        let fit = min((available.width - 40) / canvas.frame.width, (available.height - 40) / canvas.frame.height)
        let target = kind == .svg ? min(fit, 8) : min(fit, 1)
        guard abs(target - scrollView.magnification) > 0.001 else { return }
        scrollView.setMagnification(target, centeredAt: NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        zoomSettled()
    }

    @objc private func liveMagnifyEnded() { userZoomed() }

    @objc private func viewportChanged() { updateZoomLabel() }

    private func updateZoomLabel() {
        let text = "\(Int((scrollView.magnification * 100).rounded()))%"
        if zoomLabel.stringValue != text { zoomLabel.stringValue = text }
    }
}
