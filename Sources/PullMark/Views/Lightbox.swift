import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// What the lightbox shows, extracted from the rendered page when the
/// user clicks media. Images and formulas arrive as bitmaps (originals or
/// high-resolution snapshots); diagrams keep their SVG text so on-screen
/// zoom and exports stay vector-crisp.
struct LightboxContent: Identifiable {
    enum Kind { case image, diagram, formula }
    let id = UUID()
    let kind: Kind
    /// Filename stem for exports (sanitized page-side).
    let name: String
    /// Bitmap content (image/formula). Diagrams leave this nil.
    let image: NSImage?
    /// Serialized SVG (diagrams).
    let svgText: String?
    /// Original file bytes + extension when the source was resolvable
    /// (image exports prefer these over re-encoding).
    let originalBytes: Data?
    let fileExtension: String
    /// Rendered CSS size of the clicked content (diagram layout + fit).
    var naturalSize: CGSize = .zero
    /// Target width for boosted raster exports.
    var exportWidth: Double = 2048
}

/// Full-modal media inspector covering the detail area (everything but
/// the sidebar): native material scrim, native pan/zoom, native controls.
/// The page only reports what was clicked — nothing renders in-page.
struct LightboxModal: View {
    let content: LightboxContent
    /// The page under the scrim still drives the pointer — feed it the
    /// live content frame so the grab hand appears exactly there.
    var onContentFrame: ((CGRect?) -> Void)? = nil
    var onUIHover: ((Bool) -> Void)? = nil
    let onClose: () -> Void

    /// Zoom model shared by both viewers: 1.0 = natural size (pixels for
    /// bitmaps, CSS size for diagrams). The viewers translate it.
    @StateObject private var model = LightboxModel()
    /// Minimap thumbnail for diagrams, captured from the vector page the
    /// first time the content is clipped (images use themselves).
    @State private var diagramThumb: NSImage?

    var body: some View {
        ZStack {
            // Real material over the real document — the scrim IS glass.
            Rectangle()
                .fill(.ultraThinMaterial)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
            Group {
                if let image = content.image {
                    BitmapViewer(image: image, model: model,
                                 carded: content.kind == .formula,
                                 onClose: onClose)
                } else if let svg = content.svgText {
                    DiagramViewer(svgText: svg,
                                  naturalSize: content.naturalSize,
                                  model: model, onClose: onClose)
                }
            }
            VStack {
                Spacer()
                LightboxControls(content: content, model: model, onClose: onClose)
                    .padding(.bottom, 22)
                    .onHover { onUIHover?($0) }
            }
            if let thumb = content.image ?? diagramThumb, model.clipped {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        LightboxMinimap(image: thumb, model: model)
                            .padding([.bottom, .trailing], 18)
                            .onHover { onUIHover?($0) }
                    }
                }
            }
        }
        .background(LightboxKeyMonitor(model: model, onClose: onClose))
        .transition(.opacity)
        .onChange(of: model.cursorFrameKey) { _ in
            onContentFrame?(model.contentFrame())
        }
        .onAppear {
            DispatchQueue.main.async { onContentFrame?(model.contentFrame()) }
        }
        .onDisappear { onContentFrame?(nil) }
        .onChange(of: model.clipped) { clipped in
            // First clip on a diagram: grab a small fitted capture for
            // the minimap (the page restores the live view afterwards).
            guard clipped, diagramThumb == nil, content.kind == .diagram else { return }
            model.svgSnapshot?(360) { image in
                diagramThumb = image
            }
        }
    }
}

/// Shared pan/zoom state. Scale 1 = natural size; fit is computed by the
/// active viewer and pushed here so the bar and keys can use it.
@MainActor
final class LightboxModel: ObservableObject {
    @Published var scale: CGFloat = 1
    @Published var offset: CGSize = .zero
    @Published var fitScale: CGFloat = 1
    /// Content extends past the viewport (drives the minimap).
    @Published var clipped = false
    /// Content + viewport geometry, maintained by the viewer.
    @Published var contentSize: CGSize = .zero
    @Published var viewportSize: CGSize = .zero
    /// PNG capture hook (the SVG viewer snapshots its own web view at a
    /// boosted export width).
    var svgSnapshot: ((Double, @escaping (NSImage?) -> Void) -> Void)?

    var percent: Int { Int((scale * 100).rounded()) }

    func clampOffset() {
        let halfW = contentSize.width * scale / 2
        let halfH = contentSize.height * scale / 2
        let slackX = max(0, halfW - viewportSize.width / 2) + 60
        let slackY = max(0, halfH - viewportSize.height / 2) + 60
        offset.width = min(max(offset.width, -slackX), slackX)
        offset.height = min(max(offset.height, -slackY), slackY)
        clipped = contentSize.width * scale > viewportSize.width + 1
            || contentSize.height * scale > viewportSize.height + 1
    }

    func setScale(_ next: CGFloat) {
        let clamped = min(max(next, 0.1), 10)
        let factor = clamped / max(scale, 0.001)
        offset.width *= factor
        offset.height *= factor
        scale = clamped
        clampOffset()
    }

    func zoomBy(_ factor: CGFloat) { setScale(scale * factor) }

    func fit() {
        offset = .zero
        setScale(fitScale)
    }

    /// Changes whenever the content frame moves (drives cursor-region
    /// updates without publishing a new value type).
    var cursorFrameKey: String {
        let f = contentFrame()
        return "\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))"
    }

    /// Where the content currently sits in viewport coordinates.
    func contentFrame() -> CGRect {
        let w = contentSize.width * scale
        let h = contentSize.height * scale
        return CGRect(x: viewportSize.width / 2 + offset.width - w / 2,
                      y: viewportSize.height / 2 + offset.height - h / 2,
                      width: w, height: h)
    }
}

/// Native pan/zoom for bitmap content (images and formulas). Formulas
/// ride on a deliberate card — their snapshots carry the page's paper
/// color, which would otherwise float as a hard-edged slab on the blur.
private struct BitmapViewer: View {
    let image: NSImage
    @ObservedObject var model: LightboxModel
    var carded = false
    let onClose: () -> Void

    /// Pixel dimensions — 100% means image pixels on screen points.
    private var pixelSize: CGSize {
        guard let rep = image.representations.first else { return image.size }
        let w = rep.pixelsWide > 0 ? CGFloat(rep.pixelsWide) : image.size.width
        let h = rep.pixelsHigh > 0 ? CGFloat(rep.pixelsHigh) : image.size.height
        return CGSize(width: w, height: h)
    }

    var body: some View {
        GeometryReader { geometry in
            let viewport = geometry.size
            ZStack {
                content
                    .scaleEffect(model.scale)
                    .offset(model.offset)
                    .position(x: viewport.width / 2, y: viewport.height / 2)
                BitmapGestureSurface(model: model, onClose: onClose)
            }
            .onAppear { seed(viewport: viewport) }
            .onChange(of: geometry.size) { newSize in
                model.viewportSize = newSize
                model.fitScale = fitScale(in: newSize)
                model.clampOffset()
            }
        }
        .clipped()
    }

    @ViewBuilder private var content: some View {
        let base = Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: pixelSize.width, height: pixelSize.height)
        if carded {
            base
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        } else {
            base
        }
    }

    private func fitScale(in viewport: CGSize) -> CGFloat {
        min((viewport.width - 96) / max(pixelSize.width, 1),
            (viewport.height - 120) / max(pixelSize.height, 1))
    }

    private func seed(viewport: CGSize) {
        model.contentSize = pixelSize
        model.viewportSize = viewport
        model.fitScale = fitScale(in: viewport)
        // Open at fit, but no bigger than 3x.
        model.scale = min(model.fitScale, 3)
        model.offset = .zero
        model.clampOffset()
    }
}

/// The one gesture surface for both viewers: drag pans, pinch zooms,
/// double-click toggles fit, a plain click on empty space closes (the
/// scrim's own tap can't fire under a hit-testable viewer).
private struct BitmapGestureSurface: View {
    @ObservedObject var model: LightboxModel
    let onClose: () -> Void
    @GestureState private var pinchBase: CGFloat?
    @State private var dragBase: CGSize?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(pinchGesture)
            .onTapGesture(count: 2) {
                if model.scale > model.fitScale * 1.05 {
                    model.fit()
                } else {
                    model.setScale(model.fitScale * 2)
                }
            }
            .onTapGesture { location in
                // Close only when the click misses the content.
                if !model.contentFrame().contains(location) { onClose() }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let base = dragBase ?? model.offset
                if dragBase == nil {
                    dragBase = base
                    NSCursor.closedHand.set()
                }
                model.offset = CGSize(width: base.width + value.translation.width,
                                      height: base.height + value.translation.height)
                model.clampOffset()
            }
            .onEnded { _ in
                dragBase = nil
                NSCursor.arrow.set()
            }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchBase) { _, base, _ in
                if base == nil { base = model.scale }
            }
            .onChanged { value in
                model.setScale((pinchBase ?? model.scale) * value)
            }
    }
}

/// Diagram host: seeds the shared model from the diagram's natural size
/// and layers the display-only vector page under the common gesture
/// surface.
private struct DiagramViewer: View {
    let svgText: String
    let naturalSize: CGSize
    @ObservedObject var model: LightboxModel
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                SVGViewer(svgText: svgText, naturalSize: naturalSize, model: model)
                BitmapGestureSurface(model: model, onClose: onClose)
            }
            .onAppear { seed(viewport: geometry.size) }
            .onChange(of: geometry.size) { newSize in
                model.viewportSize = newSize
                model.fitScale = fitScale(in: newSize)
                model.clampOffset()
            }
        }
        .clipped()
    }

    private func fitScale(in viewport: CGSize) -> CGFloat {
        min((viewport.width - 96) / max(naturalSize.width, 1),
            (viewport.height - 120) / max(naturalSize.height, 1))
    }

    private func seed(viewport: CGSize) {
        model.contentSize = naturalSize
        model.viewportSize = viewport
        model.fitScale = fitScale(in: viewport)
        // Vector content upsizes crisply — open at fit, capped at 3x.
        model.scale = min(model.fitScale, 3)
        model.offset = .zero
        model.clampOffset()
    }
}

/// Diagrams stay vector: a display-only transparent page holds the SVG
/// at its natural size and a CSS transform mirrors the native model —
/// the web view never handles input (hit-test transparent) and never
/// writes model state, so gestures, fit, and percent all behave exactly
/// like the bitmap path.
private struct SVGViewer: NSViewRepresentable {
    let svgText: String
    /// The diagram's rendered CSS size, stamped onto the SVG so the bare
    /// page can't squeeze it to viewport width (mermaid ships width=100%).
    let naturalSize: CGSize
    @ObservedObject var model: LightboxModel

    final class DisplayWebView: WKWebView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = DisplayWebView(frame: .zero, configuration: configuration)
        if webView.responds(to: Selector(("setDrawsBackground:")))
            || webView.responds(to: Selector(("_setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.underPageBackgroundColor = .clear
        let w = Int(naturalSize.width.rounded())
        let h = Int(naturalSize.height.rounded())
        let page = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;background:transparent;overflow:hidden;\
        width:100vw;height:100vh}
        #stage{position:absolute;left:50%;top:50%;width:\(w)px;height:\(h)px;\
        margin-left:-\(w / 2)px;margin-top:-\(h / 2)px;\
        transform-origin:center center;will-change:transform}
        #stage svg{width:\(w)px !important;height:\(h)px !important;\
        max-width:none !important;display:block}</style>
        <script>function __set(x,y,s){var e=document.getElementById('stage');\
        if(e){e.style.transform='translate('+x+'px,'+y+'px) scale('+s+')';}}</script>
        </head><body><div id="stage">\(svgText)</div></body></html>
        """
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(page, baseURL: nil)
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Read-only mirror of the model — never write model state here.
        webView.evaluateJavaScript(
            "typeof __set==='function'&&__set(\(model.offset.width),"
            + "\(model.offset.height),\(model.scale));",
            completionHandler: nil)
        // Register the export hook once.
        context.coordinator.register(model: model, naturalSize: naturalSize)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var registered = false
        private weak var model: LightboxModel?

        /// The seed transform lands before the page exists — re-apply the
        /// live model the moment the page is ready.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let model else { return }
            webView.evaluateJavaScript(
                "typeof __set==='function'&&__set(\(model.offset.width),"
                + "\(model.offset.height),\(model.scale));",
                completionHandler: nil)
        }

        func register(model: LightboxModel, naturalSize: CGSize) {
            self.model = model
            guard !registered else { return }
            registered = true
            // Deferred: registering mutates observed state indirectly and
            // must stay out of the view-update pass.
            DispatchQueue.main.async { [weak self] in
                model.svgSnapshot = { [weak self] exportWidth, completion in
                    self?.snapshot(model: model, naturalSize: naturalSize,
                                   exportWidth: exportWidth, completion: completion)
                }
            }
        }

        /// PNG of the whole diagram: show it fitted, capture its bounds at
        /// boosted width, then put the user's view back.
        private func snapshot(model: LightboxModel, naturalSize: CGSize,
                              exportWidth: Double,
                              completion: @escaping (NSImage?) -> Void) {
            guard let webView else { return completion(nil) }
            let bounds = webView.bounds
            let fit = min(bounds.width / max(naturalSize.width, 1),
                          bounds.height / max(naturalSize.height, 1), 1)
            webView.evaluateJavaScript("__set(0,0,\(fit));") { _, _ in
                let w = naturalSize.width * fit
                let h = naturalSize.height * fit
                let configuration = WKSnapshotConfiguration()
                configuration.rect = CGRect(x: (bounds.width - w) / 2,
                                            y: (bounds.height - h) / 2,
                                            width: w, height: h)
                configuration.snapshotWidth = NSNumber(
                    value: min(max(exportWidth, Double(w)), 4096))
                webView.takeSnapshot(with: configuration) { image, _ in
                    // Restore the live transform.
                    webView.evaluateJavaScript(
                        "__set(\(model.offset.width),\(model.offset.height),"
                        + "\(model.scale));", completionHandler: nil)
                    completion(image)
                }
            }
        }
    }
}

/// The floating control capsule: zoom out, editable percent, zoom in,
/// fit, actual size, save (format menu for diagrams), share, close.
private struct LightboxControls: View {
    let content: LightboxContent
    @ObservedObject var model: LightboxModel
    let onClose: () -> Void

    private final class AnchorBox {
        weak var view: NSView?
        var retainedPicker: NSSharingServicePicker?
    }
    private struct AnchorReader: NSViewRepresentable {
        let box: AnchorBox
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            box.view = view
            return view
        }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
    @State private var anchor = AnchorBox()
    @State private var saveAnchor = AnchorBox()
    @State private var menuPresenter = FormatMenuPresenter()
    @State private var editingPercent = false
    @State private var percentText = ""
    @FocusState private var percentFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            barButton("minus.magnifyingglass", "Zoom out (-)") { model.zoomBy(0.8) }
            percentControl
            barButton("plus.magnifyingglass", "Zoom in (+)") { model.zoomBy(1.25) }
            barButton("arrow.up.left.and.arrow.down.right", "Fit (0)") { model.fit() }
            barButton("1.magnifyingglass", "Actual size (1)") { model.setScale(1) }
            divider
            if content.kind == .diagram {
                barButton("square.and.arrow.down", "Save As…") {
                    popFormatMenu(from: saveAnchor.view,
                                  svgTitle: "Save as SVG…", pngTitle: "Save as PNG…",
                                  action: save)
                }
                .background(AnchorReader(box: saveAnchor))
                barButton("square.and.arrow.up", "Share") {
                    popFormatMenu(from: anchor.view,
                                  svgTitle: "Share as SVG", pngTitle: "Share as PNG",
                                  action: share)
                }
                .background(AnchorReader(box: anchor))
            } else {
                barButton("square.and.arrow.down", "Save As…") { save(nil) }
                barButton("square.and.arrow.up", "Share") { share(nil) }
                    .background(AnchorReader(box: anchor))
            }
            divider
            barButton("xmark", "Close (Esc)", action: onClose)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
    }

    private func barButton(_ symbol: String, _ title: String,
                           action: @escaping () -> Void) -> some View {
        LightboxBarButton(symbol: symbol, title: title, action: action)
    }

    private var divider: some View {
        Divider().frame(height: 16).padding(.horizontal, 3)
    }

    @ViewBuilder private var percentControl: some View {
        if editingPercent {
            TextField("", text: $percentText)
                .textFieldStyle(.plain)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 44)
                .focused($percentFocused)
                .onSubmit { commitPercent() }
                .onExitCommand { editingPercent = false }
                .onAppear { percentFocused = true }
                .onChange(of: percentFocused) { focused in
                    if !focused { editingPercent = false }
                }
        } else {
            Text("\(model.percent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)
                .contentShape(Rectangle())
                .onTapGesture {
                    percentText = "\(model.percent)"
                    editingPercent = true
                }
                .help("Click to type a zoom level")
        }
    }

    private func commitPercent() {
        editingPercent = false
        let digits = percentText.filter(\.isNumber)
        guard let value = Int(digits) else { return }
        model.setScale(CGFloat(min(max(value, 10), 1000)) / 100)
    }

    /// The format picker as a real menu popped from a real button —
    /// SwiftUI's borderless Menu never delivers hover to its label, so
    /// dropdowns would read as dead next to buttons that light up.
    final class FormatMenuPresenter: NSObject {
        var actions: [() -> Void] = []
        @objc func fire(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag]()
        }
    }

    private func popFormatMenu(from view: NSView?,
                               svgTitle: String, pngTitle: String,
                               action: @escaping (ExportFormat?) -> Void) {
        guard let view else { return }
        menuPresenter.actions = [{ action(.svg) }, { action(.png) }]
        let menu = NSMenu()
        for (tag, title) in [(0, svgTitle), (1, pngTitle)] {
            let item = NSMenuItem(title: title,
                                  action: #selector(FormatMenuPresenter.fire(_:)),
                                  keyEquivalent: "")
            item.target = menuPresenter
            item.tag = tag
            menu.addItem(item)
        }
        // Anchoring the LAST item at the button's top edge makes the menu
        // unfold upward — downward would cover the capsule at the screen
        // bottom.
        menu.popUp(positioning: menu.items.last,
                   at: NSPoint(x: 0, y: view.bounds.height + 6), in: view)
    }

    enum ExportFormat { case svg, png }

    private func exportData(format: ExportFormat?,
                            completion: @escaping (Data, String) -> Void) {
        switch content.kind {
        case .diagram where format != .png:
            if let svg = content.svgText {
                completion(Data(svg.utf8), "svg")
            }
        case .diagram:
            // PNG of a diagram: fitted, boosted-width capture of the
            // vector page, restoring the live view afterwards.
            model.svgSnapshot?(content.exportWidth) { image in
                guard let image, let png = Self.pngData(image) else { return }
                completion(png, "png")
            }
        default:
            if let bytes = content.originalBytes {
                completion(bytes, content.fileExtension)
            } else if let image = content.image, let png = Self.pngData(image) {
                completion(png, "png")
            }
        }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func save(_ format: ExportFormat?) {
        exportData(format: format) { data, ext in
            let panel = NSSavePanel()
            if let type = UTType(filenameExtension: ext) {
                panel.allowedContentTypes = [type]
            }
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = content.name + "." + ext
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    private func share(_ format: ExportFormat?) {
        exportData(format: format) { data, ext in
            guard let anchorView = anchor.view else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(content.name + "." + ext)
            guard (try? data.write(to: url)) != nil else { return }
            let picker = NSSharingServicePicker(items: [url])
            anchor.retainedPicker = picker
            picker.show(relativeTo: anchorView.bounds, of: anchorView,
                        preferredEdge: .minY)
        }
    }
}

/// The interactive overview shown while a bitmap is clipped: click or
/// drag to pan the main view.
private struct LightboxMinimap: View {
    let image: NSImage
    @ObservedObject var model: LightboxModel

    private var thumbSize: CGSize {
        let scale = min(180 / max(model.contentSize.width, 1),
                        120 / max(model.contentSize.height, 1), 1)
        return CGSize(width: model.contentSize.width * scale,
                      height: model.contentSize.height * scale)
    }

    var body: some View {
        let visible = visibleRect()
        ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .frame(width: thumbSize.width, height: thumbSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.14))
                )
                .frame(width: visible.width * thumbSize.width,
                       height: visible.height * thumbSize.height)
                .offset(x: visible.minX * thumbSize.width,
                        y: visible.minY * thumbSize.height)
                .allowsHitTesting(false)
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in centerOn(point: value.location) }
        )
    }

    /// The viewport as a normalized rect within the content.
    private func visibleRect() -> CGRect {
        let contentW = model.contentSize.width * model.scale
        let contentH = model.contentSize.height * model.scale
        guard contentW > 0, contentH > 0 else { return .zero }
        let left = model.viewportSize.width / 2 + model.offset.width - contentW / 2
        let top = model.viewportSize.height / 2 + model.offset.height - contentH / 2
        let x0 = max(0, -left / contentW)
        let y0 = max(0, -top / contentH)
        let x1 = min(1, (model.viewportSize.width - left) / contentW)
        let y1 = min(1, (model.viewportSize.height - top) / contentH)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    private func centerOn(point: CGPoint) {
        let nx = min(max(point.x / max(thumbSize.width, 1), 0), 1)
        let ny = min(max(point.y / max(thumbSize.height, 1), 0), 1)
        model.offset.width = (0.5 - nx) * model.contentSize.width * model.scale
        model.offset.height = (0.5 - ny) * model.contentSize.height * model.scale
        model.clampOffset()
    }
}

/// Keyboard for the modal: Esc closes; -, +, 0, 1 (bare or with ⌘) drive
/// the zoom. A local monitor sees the keys before the menu bar, so ⌘+
/// can't zoom the document behind the scrim.
private struct LightboxKeyMonitor: NSViewRepresentable {
    @ObservedObject var model: LightboxModel
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.hostView = view
        context.coordinator.install(model: model, onClose: onClose)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(model: model, onClose: onClose)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var monitor: Any?
        private var model: LightboxModel?
        private var onClose: (() -> Void)?
        weak var hostView: NSView?

        private var scrollMonitor: Any?

        func install(model: LightboxModel, onClose: @escaping () -> Void) {
            update(model: model, onClose: onClose)
            guard monitor == nil else { return }
            // Wheel events for the whole window belong to the inspector
            // while it's open (the document is frozen anyway): plain
            // scroll pans, ⌘-scroll zooms.
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let model = self.model,
                      event.window === self.hostView?.window else { return event }
                if event.modifierFlags.contains(.command) {
                    model.zoomBy(1 + event.scrollingDeltaY * 0.005)
                } else {
                    model.offset.width += event.scrollingDeltaX
                    model.offset.height += event.scrollingDeltaY
                    model.clampOffset()
                }
                return nil
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let model = self.model,
                      event.window === self.hostView?.window else { return event }
                let modifiers = event.modifierFlags
                    .intersection([.command, .shift, .option, .control])
                let plain = modifiers.isEmpty
                let command = modifiers == [.command] || modifiers == [.command, .shift]
                // Never swallow keys aimed at a text field (the percent
                // editor) except the zoom chords that must not leak.
                let editingText = event.window?.firstResponder is NSTextView
                let key = event.charactersIgnoringModifiers
                if key == "\u{1B}", plain {
                    // While the percent field is being edited, Esc belongs
                    // to it (cancels the edit) — not to the modal.
                    if editingText { return event }
                    self.onClose?()
                    return nil
                }
                guard plain || command, let key, !key.isEmpty,
                      !(editingText && plain) else { return event }
                switch key {
                case "+", "=":
                    model.zoomBy(1.25)
                    return nil
                case "-":
                    model.zoomBy(0.8)
                    return nil
                case "0":
                    model.fit()
                    return nil
                case "1" where plain:
                    model.setScale(1)
                    return nil
                default:
                    return event
                }
            }
        }

        func update(model: LightboxModel, onClose: @escaping () -> Void) {
            self.model = model
            self.onClose = onClose
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            monitor = nil
            scrollMonitor = nil
        }
    }
}

/// Capsule-bar button with an explicit hover highlight.
struct LightboxBarButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .background(
                    hovered ? Color.primary.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(Rectangle())
                .help(title)
        }
        .buttonStyle(.borderless)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}


/// Builds LightboxContent from a page request and presents it: diagrams
/// keep their SVG, images prefer original bytes, formulas (and images
/// whose bytes can't be resolved) come in as boosted snapshots taken
/// before the modal covers the page.
@MainActor
func presentLightbox(_ request: LightboxRequest, proxy: WebViewProxy, state: AppState) {
    proxy.setInspecting(true)
    switch request.kind {
    case "svg":
        guard let svg = request.svg, !svg.isEmpty else { return }
        state.lightbox = LightboxContent(kind: .diagram, name: request.name,
                                         image: nil, svgText: svg,
                                         originalBytes: nil, fileExtension: "svg",
                                         naturalSize: request.rect.size,
                                         exportWidth: request.exportWidth)
    case "img":
        if let bytes = proxy.originalImageBytes(src: request.src),
           let image = NSImage(data: bytes) {
            state.lightbox = LightboxContent(
                kind: .image, name: request.name, image: image, svgText: nil,
                originalBytes: bytes,
                fileExtension: WebViewProxy.imageExtension(for: request.src))
        } else {
            proxy.snapshotRect(request.rect, exportWidth: request.exportWidth) { image in
                guard let image else { return }
                state.lightbox = LightboxContent(kind: .image, name: request.name,
                                                 image: image, svgText: nil,
                                                 originalBytes: nil, fileExtension: "png")
            }
        }
    default:
        proxy.snapshotRect(request.rect, exportWidth: request.exportWidth) { image in
            guard let image else { return }
            state.lightbox = LightboxContent(kind: .formula, name: request.name,
                                             image: image, svgText: nil,
                                             originalBytes: nil, fileExtension: "png")
        }
    }
}
