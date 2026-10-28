import ScannerCore
import SwiftUI

/// El gráfico de anillos de la carpeta enfocada, con hover, clic, menú contextual
/// y la animación de zoom.
struct ChartView: View {
    let focus: FileNode
    @Environment(ScanSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let layout = session.layout(for: focus, in: size)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let hover = session.hover
            let transition = session.zoomTransition
            let style = Style(byType: session.colorByType, dark: colorScheme == .dark,
                              highlighted: session.highlightedCategory)

            ZStack {
                // El reloj solo corre durante la animación de zoom.
                TimelineView(.animation(paused: transition == nil)) { timeline in
                    Canvas { context, _ in
                        if let transition, let frame = zoomFrame(transition, at: timeline.date, size: size) {
                            drawZoom(frame, center: center, style: style, in: &context)
                        } else {
                            draw(layout, center: center, hover: hover, style: style, in: &context)
                        }
                    }
                }
                CenterLabel(focus: focus, hover: hover, width: layout.innerRadius * 1.5)
                    .position(center)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .pointerStyle(isClickable(hover) ? .link : nil)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    session.setHover(hitTest(location, center: center, layout: layout))
                case .ended:
                    session.setHover(nil)
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                switch hitTest(location, center: center, layout: layout) {
                case .center:
                    session.goUp()
                case .arc(let arc):
                    if let node = arc.node { session.zoom(to: node) }
                case nil:
                    break
                }
            }
            .contextMenu {
                if let node = hover?.arc?.node, !node.isSynthetic {
                    NodeMenu(node: node)
                } else if case .center = hover {
                    NodeMenu(node: focus, isFocus: true)
                }
            }
            .task(id: transition?.start) {
                guard let transition else { return }
                try? await Task.sleep(for: .seconds(ZoomTransition.duration))
                session.endZoomTransition(transition)
            }
        }
    }

    private func isClickable(_ hover: ChartHover?) -> Bool {
        switch hover {
        case .center: focus.parent != nil
        case .arc(let arc): arc.node.map { $0.isDirectory && !$0.children.isEmpty } ?? false
        case nil: false
        }
    }

    private func hitTest(_ point: CGPoint, center: CGPoint, layout: SunburstLayout) -> ChartHover? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = (dx * dx + dy * dy).squareRoot()
        if radius < layout.innerRadius - 2 { return .center }
        return layout.arc(radius: radius, angle: SunburstLayout.angle(x: dx, y: dy)).map(ChartHover.arc)
    }

    // MARK: - Dibujo

    private struct Style {
        let byType: Bool
        let dark: Bool
        let highlighted: FileCategory?
    }

    private func draw(_ layout: SunburstLayout, center: CGPoint, hover: ChartHover?, style: Style, in context: inout GraphicsContext) {
        let hovered = hover?.arc
        drawCenterDisc(layout, center: center, highlighted: hover == .center && focus.parent != nil, in: &context)

        for ring in layout.rings {
            for arc in ring {
                let inner = layout.innerRadius + layout.ringWidth * Double(arc.depth)
                let path = Self.sector(center: center, inner: inner, outer: inner + layout.ringWidth, start: arc.start, end: arc.end)
                let color = Palette.color(for: arc, in: layout, byType: style.byType, dark: style.dark)
                context.fill(path, with: .color(color.opacity(isDimmed(arc, hovered: hovered, style: style) ? 0.4 : 1)))
                if arc.node?.kind == .free {
                    context.stroke(path, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
                }
            }
        }

        if let hovered {
            let inner = layout.innerRadius + layout.ringWidth * Double(hovered.depth)
            let path = Self.sector(center: center, inner: inner, outer: inner + layout.ringWidth, start: hovered.start, end: hovered.end)
            context.stroke(path, with: .color(.primary.opacity(0.55)), lineWidth: 1.25)
        }
    }

    private func isDimmed(_ arc: SunburstArc, hovered: SunburstArc?, style: Style) -> Bool {
        if let hovered { return !arc.isWithin(hovered) }
        if let category = style.highlighted, style.byType {
            guard let node = arc.node, !node.isSynthetic else { return true }
            return (node.isDirectory ? node.dominantCategory : node.category) != category
        }
        return false
    }

    private func drawCenterDisc(_ layout: SunburstLayout, center: CGPoint, highlighted: Bool, in context: inout GraphicsContext) {
        let radius = layout.innerRadius - 3
        let disc = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.fill(disc, with: .color(.primary.opacity(highlighted ? 0.09 : 0.045)))
    }

    // MARK: - Animación de zoom

    /// Un cuadro de la animación. El layout "interior" es el de la carpeta más profunda:
    /// con `progress` 0 se dibuja donde estaba dentro del exterior, con 1 ocupa todo.
    private struct ZoomFrame {
        let outer: SunburstLayout
        let inner: SunburstLayout
        /// El arco de la carpeta interior dentro del exterior; `nil` si no se veía
        /// (o no están relacionadas): entonces se funden sin moverse.
        let anchor: SunburstArc?
        let progress: Double
    }

    private func zoomFrame(_ transition: ZoomTransition, at date: Date, size: CGSize) -> ZoomFrame? {
        var t = (date.timeIntervalSince(transition.start) / ZoomTransition.duration).clamped(to: 0...1)
        #if DEBUG
        if let frozen = session.debugFrozenZoomProgress { t = frozen }
        #endif
        guard t < 1 else { return nil }
        // easeInOutCubic
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        let zoomingOut = transition.from.isDescendant(of: transition.to)
        let outerNode = zoomingOut ? transition.to : transition.from
        let innerNode = zoomingOut ? transition.from : transition.to
        let outer = session.layout(for: outerNode, in: size)
        let inner = session.layout(for: innerNode, in: size)
        let related = innerNode.isDescendant(of: outerNode)
        return ZoomFrame(
            outer: outer,
            inner: inner,
            anchor: related ? outer.arc(for: innerNode) : nil,
            progress: zoomingOut ? 1 - eased : eased
        )
    }

    private func drawZoom(_ frame: ZoomFrame, center: CGPoint, style: Style, in context: inout GraphicsContext) {
        let outer = frame.outer
        let inner = frame.inner
        let p = frame.progress
        drawCenterDisc(inner, center: center, highlighted: false, in: &context)
        // Los anillos que entran desde afuera no se salen del círculo.
        let limit = outer.outerRadius + 1
        context.clip(to: Path(ellipseIn: CGRect(x: center.x - limit, y: center.y - limit, width: limit * 2, height: limit * 2)))

        // Exterior: se desvanece, salvo lo que está dentro del interior (lo dibuja el interior).
        let outerOpacity = 1 - p
        if outerOpacity > 0.01 {
            for ring in outer.rings {
                for arc in ring {
                    if let anchor = frame.anchor, arc.depth > anchor.depth, arc.owner.isDescendant(of: inner.focus) { continue }
                    let r = outer.innerRadius + outer.ringWidth * Double(arc.depth)
                    let path = Self.sector(center: center, inner: r, outer: r + outer.ringWidth, start: arc.start, end: arc.end)
                    let color = Palette.color(for: arc, in: outer, byType: style.byType, dark: style.dark)
                    context.fill(path, with: .color(color.opacity(outerOpacity)))
                }
            }
        }

        // Interior: de su lugar dentro del exterior a ocupar todo el círculo.
        let twoPi = 2 * Double.pi
        let innerOpacity = frame.anchor == nil ? p : 1
        for ring in inner.rings {
            for arc in ring {
                var start = arc.start
                var end = arc.end
                var depth = Double(arc.depth)
                var position = arc.mid / inner.contentSpan
                if let anchor = frame.anchor {
                    let span = anchor.end - anchor.start
                    let embeddedStart = anchor.start + arc.start / twoPi * span
                    let embeddedEnd = anchor.start + arc.end / twoPi * span
                    let embeddedDepth = Double(anchor.depth + 1 + arc.depth)
                    let embeddedPosition = (embeddedStart + embeddedEnd) / 2 / outer.contentSpan
                    start = embeddedStart + (start - embeddedStart) * p
                    end = embeddedEnd + (end - embeddedEnd) * p
                    depth = embeddedDepth + (depth - embeddedDepth) * p
                    position = embeddedPosition + (position - embeddedPosition) * p
                }
                let r = inner.innerRadius + inner.ringWidth * depth
                // Lo que todavía es una astilla no vale la pena dibujarlo.
                guard (end - start) * r > 0.3, r < limit else { continue }
                let path = Self.sector(center: center, inner: r, outer: r + inner.ringWidth, start: start, end: end)
                let color = Palette.color(for: arc.node, position: position, depth: depth, byType: style.byType, dark: style.dark)
                context.fill(path, with: .color(color.opacity(innerOpacity)))
            }
        }
    }

    /// Sector anular con un pequeño margen para que se vea el fondo entre segmentos.
    static func sector(center: CGPoint, inner: Double, outer: Double, start: Double, end: Double) -> Path {
        let radialGap = 0.6
        let r0 = inner + radialGap
        let r1 = max(r0 + 0.5, outer - radialGap)
        var a0 = start
        var a1 = end
        let full = end - start >= 2 * .pi - 1e-6
        if !full {
            // Separación angular de ~0,6 pt medida en el borde interno.
            let gap = min(0.6 / r0, (end - start) * 0.25)
            a0 += gap
            a1 -= gap
        }
        // Ángulos del gráfico: 0 arriba y en sentido horario. En SwiftUI (y hacia abajo)
        // eso es restar π/2, y "clockwise: false" avanza en sentido horario en pantalla.
        let s = Angle.radians(a0 - .pi / 2)
        let e = Angle.radians(a1 - .pi / 2)
        var path = Path()
        path.addArc(center: center, radius: r1, startAngle: s, endAngle: e, clockwise: false)
        if full {
            path.closeSubpath()
        }
        path.addArc(center: center, radius: r0, startAngle: e, endAngle: s, clockwise: true)
        path.closeSubpath()
        return path
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Texto en el centro: lo que está bajo el cursor o, si no, la carpeta enfocada.
private struct CenterLabel: View {
    let focus: FileNode
    let hover: ChartHover?
    let width: Double

    var body: some View {
        VStack(spacing: 3) {
            // En una línea si entra, aunque sea con letra algo más chica; si no, en dos.
            ViewThatFits(in: .horizontal) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Text(Format.bytes(size))
                .font(.system(size: width > 150 ? 22 : 17, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText())
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .multilineTextAlignment(.center)
        .frame(width: width)
    }

    private var title: String {
        switch hover {
        case .arc(let arc):
            if case .smaller(_, let count, _) = arc.content { return "\(count.formatted()) elementos más chicos" }
            return arc.node?.name ?? ""
        case .center, nil:
            return focus.name
        }
    }

    private var size: Int64 {
        hover?.arc?.size ?? focus.size
    }

    private var subtitle: String {
        switch hover {
        case .arc(let arc):
            return Format.percent(arc.size, of: focus.size)
        case .center where focus.parent != nil:
            return "↑ Carpeta superior"
        default:
            return Format.filesCompact(focus.fileCount)
        }
    }
}

/// Acciones del menú contextual sobre un archivo o carpeta.
struct NodeMenu: View {
    let node: FileNode
    var isFocus = false
    @Environment(ScanSession.self) private var session

    var body: some View {
        if node.isDirectory && !isFocus && !node.children.isEmpty {
            Button("Acercar") { session.zoom(to: node) }
        }
        Button("Abrir") { session.openItem(node) }
        Button("Mostrar en Finder") { session.reveal(node) }
        Button("Copiar ruta") { session.copyPath(node) }
        if node.isDirectory {
            Button("Re-escanear") { session.rescan(node) }
        }
        if node.parent != nil && !isFocus {
            Divider()
            Button("Mover a la Papelera…", role: .destructive) { session.pendingTrash = node }
        }
    }
}
