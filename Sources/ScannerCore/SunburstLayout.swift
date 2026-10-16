import Foundation

/// Un segmento del gráfico. Los ángulos están en radianes, con 0 arriba
/// y creciendo en sentido horario.
public struct SunburstArc: Sendable, Equatable {
    public enum Content: Sendable {
        case node(FileNode)
        /// Elementos de `parent` demasiado chicos para dibujarse por separado.
        case smaller(parent: FileNode, count: Int, size: Int64)
    }

    public let content: Content
    /// 0 es el anillo más interno.
    public let depth: Int
    public let start: Double
    public let end: Double

    public var mid: Double { (start + end) / 2 }

    public var node: FileNode? {
        if case .node(let node) = content { node } else { nil }
    }

    /// El nodo, o la carpeta que contiene a los elementos agrupados.
    public var owner: FileNode {
        switch content {
        case .node(let node): node
        case .smaller(let parent, _, _): parent
        }
    }

    public var size: Int64 {
        switch content {
        case .node(let node): node.size
        case .smaller(_, _, let size): size
        }
    }

    public var isSmaller: Bool {
        if case .smaller = content { true } else { false }
    }

    /// Si este arco es `other` o está dentro de él en el gráfico.
    public func isWithin(_ other: SunburstArc) -> Bool {
        if self == other { return true }
        guard let ancestor = other.node, ancestor.isDirectory, depth > other.depth else { return false }
        return owner.isDescendant(of: ancestor)
    }

    public static func == (a: SunburstArc, b: SunburstArc) -> Bool {
        a.depth == b.depth && a.start == b.start && a.end == b.end
            && a.owner === b.owner && a.isSmaller == b.isSmaller
    }
}

/// Distribución de los anillos para una carpeta enfocada.
public struct SunburstLayout: Sendable {
    public let focus: FileNode
    public let innerRadius: Double
    public let ringWidth: Double
    public let ringCount: Int
    /// `rings[d]` son los arcos del anillo `d`, ordenados por ángulo.
    public private(set) var rings: [[SunburstArc]]

    /// Ángulo que ocupan los datos reales, sin libre ni sistema. La paleta reparte
    /// los tonos solo sobre esta parte.
    public private(set) var contentSpan: Double = 2 * .pi

    public var outerRadius: Double { innerRadius + ringWidth * Double(ringCount) }

    /// - Parameter minArcLength: largo mínimo en puntos, a mitad del anillo, para
    ///   dibujar un elemento por separado. Lo más chico se agrupa.
    public init(focus: FileNode, innerRadius: Double, ringWidth: Double, ringCount: Int, minArcLength: Double = 3) {
        self.focus = focus
        self.innerRadius = innerRadius
        self.ringWidth = ringWidth
        self.ringCount = ringCount
        self.rings = Array(repeating: [], count: max(0, ringCount))
        place(focus, depth: 0, start: 0, span: 2 * .pi, minArcLength: minArcLength)
        if let firstSynthetic = rings.first?.first(where: { $0.node?.isSynthetic == true }), firstSynthetic.start > 0 {
            contentSpan = firstSynthetic.start
        }
    }

    private mutating func place(_ node: FileNode, depth: Int, start: Double, span: Double, minArcLength: Double) {
        guard depth < ringCount, node.size > 0, !node.children.isEmpty else { return }
        let radius = innerRadius + ringWidth * (Double(depth) + 0.5)
        let scale = span / Double(node.size)
        var angle = start
        var smallCount = 0
        var smallSize: Int64 = 0

        func flushSmall(into layout: inout SunburstLayout) {
            guard smallCount > 0 else { return }
            let smallSpan = Double(smallSize) * scale
            if smallSpan * radius >= minArcLength / 3 {
                layout.rings[depth].append(SunburstArc(
                    content: .smaller(parent: node, count: smallCount, size: smallSize),
                    depth: depth, start: angle, end: angle + smallSpan
                ))
            }
            angle += smallSpan
            smallCount = 0
            smallSize = 0
        }

        for child in node.children {
            let childSpan = Double(child.size) * scale
            if child.isSynthetic {
                flushSmall(into: &self)
            } else if childSpan * radius < minArcLength {
                // Ordenados por tamaño: lo que sigue (salvo sintéticos) también es chico.
                smallCount += 1
                smallSize += child.size
                continue
            }
            if childSpan > 0 {
                rings[depth].append(SunburstArc(content: .node(child), depth: depth, start: angle, end: angle + childSpan))
                if child.isDirectory {
                    place(child, depth: depth + 1, start: angle, span: childSpan, minArcLength: minArcLength)
                }
            }
            angle += childSpan
        }
        flushSmall(into: &self)
    }

    /// Ángulo del punto (`x`, `y`) relativo al centro, con y hacia abajo.
    public static func angle(x: Double, y: Double) -> Double {
        let angle = atan2(x, -y)
        return angle < 0 ? angle + 2 * .pi : angle
    }

    public func arc(radius: Double, angle: Double) -> SunburstArc? {
        guard radius >= innerRadius else { return nil }
        let depth = Int((radius - innerRadius) / ringWidth)
        guard depth < ringCount else { return nil }
        let ring = rings[depth]
        var low = 0
        var high = ring.count
        while low < high {
            let mid = (low + high) / 2
            if ring[mid].start <= angle { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let arc = ring[low - 1]
        return angle < arc.end ? arc : nil
    }
}
