import ScannerCore
import SwiftUI

/// Arcoíris suave: el tono sigue el ángulo, así los vecinos cambian de a poco
/// como en el Scanner original, pero en tonos pastel y planos.
enum Palette {
    /// - Parameter contentSpan: ángulo ocupado por datos reales (ver `SunburstLayout.contentSpan`).
    static func color(for arc: SunburstArc, contentSpan: Double, dark: Bool) -> Color {
        guard let node = arc.node else {
            return dark ? Color(white: 0.30) : Color(white: 0.84)
        }
        switch node.kind {
        case .free:
            return .primary.opacity(0.06)
        case .other:
            return dark ? Color(white: 0.36) : Color(white: 0.76)
        case .directory, .file:
            // 0,9 de la vuelta: el último tono no se confunde con el primero.
            let position = min(1, arc.mid / max(contentSpan, 0.001))
            let hue = (0.56 + position * 0.9).truncatingRemainder(dividingBy: 1)
            let depth = Double(arc.depth)
            var saturation = max(0.30, 0.56 - depth * 0.035)
            var brightness = dark ? 0.80 + min(depth * 0.012, 0.08) : 0.90 + min(depth * 0.01, 0.07)
            if node.kind == .file {
                saturation *= 0.42
                brightness = min(1, brightness + (dark ? -0.06 : 0.03))
            }
            return Color(hue: hue, saturation: saturation, brightness: brightness)
        }
    }
}
