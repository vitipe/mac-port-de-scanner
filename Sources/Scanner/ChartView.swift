import ScannerCore
import SwiftUI

/// El gráfico de anillos de la carpeta enfocada, con hover, clic y menú contextual.
struct ChartView: View {
    let focus: FileNode
    @Environment(ScanSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let layout = session.layout(for: focus, in: geometry.size)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let hover = session.hover

            ZStack {
                Canvas { context, _ in
                    draw(layout, center: center, hover: hover, in: &context)
                }
                CenterLabel(focus: focus, hover: hover, width: layout.innerRadius * 1.5)
                    .position(center)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
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

    private func draw(_ layout: SunburstLayout, center: CGPoint, hover: ChartHover?, in context: inout GraphicsContext) {
        let dark = colorScheme == .dark
        let hovered = hover?.arc

        let centerDisc = Path(ellipseIn: CGRect(
            x: center.x - layout.innerRadius + 3, y: center.y - layout.innerRadius + 3,
            width: (layout.innerRadius - 3) * 2, height: (layout.innerRadius - 3) * 2
        ))
        let canGoUp = focus.parent != nil
        context.fill(centerDisc, with: .color(.primary.opacity(hover == .center && canGoUp ? 0.09 : 0.045)))

        for ring in layout.rings {
            for arc in ring {
                let inner = layout.innerRadius + layout.ringWidth * Double(arc.depth)
                let path = Self.sector(center: center, inner: inner, outer: inner + layout.ringWidth, start: arc.start, end: arc.end)
                let dimmed = hovered.map { !arc.isWithin($0) } ?? false
                let color = Palette.color(for: arc, contentSpan: layout.contentSpan, dark: dark)
                context.fill(path, with: .color(color.opacity(dimmed ? 0.5 : 1)))
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
            path.addArc(center: center, radius: r0, startAngle: e, endAngle: s, clockwise: true)
        } else {
            path.addArc(center: center, radius: r0, startAngle: e, endAngle: s, clockwise: true)
        }
        path.closeSubpath()
        return path
    }
}

/// Texto en el centro: lo que está bajo el cursor o, si no, la carpeta enfocada.
private struct CenterLabel: View {
    let focus: FileNode
    let hover: ChartHover?
    let width: Double

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(Format.bytes(size))
                .font(.system(size: width > 150 ? 22 : 17, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
            return Format.files(focus.fileCount)
        }
    }
}

/// Acciones del menú contextual sobre un archivo o carpeta.
struct NodeMenu: View {
    let node: FileNode
    var isFocus = false
    @Environment(ScanSession.self) private var session

    var body: some View {
        if node.isDirectory && !isFocus {
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
