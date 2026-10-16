import ScannerCore
import SwiftUI

/// Colores del gráfico, en tonos pastel y planos.
///
/// - Arcoíris (por defecto): el tono sigue el ángulo, así los vecinos cambian de a
///   poco como en el Scanner original.
/// - Por tipo: cada categoría tiene su color; una carpeta toma el de lo que más ocupa.
enum Palette {
    static func color(for arc: SunburstArc, in layout: SunburstLayout, byType: Bool, dark: Bool) -> Color {
        color(for: arc.node, position: arc.mid / layout.contentSpan, depth: Double(arc.depth), byType: byType, dark: dark)
    }

    /// - Parameters:
    ///   - position: posición del segmento en la vuelta, de 0 a 1 (solo arcoíris).
    ///   - depth: anillo; puede ser fraccionario durante la animación de zoom.
    static func color(for node: FileNode?, position: Double, depth: Double, byType: Bool, dark: Bool) -> Color {
        guard let node else {
            // Grupo de elementos chicos.
            return dark ? Color(white: 0.30) : Color(white: 0.84)
        }
        switch node.kind {
        case .free:
            return .primary.opacity(0.06)
        case .other:
            let shade = min(depth * 0.04, 0.12)
            return dark ? Color(white: 0.34 + shade) : Color(white: 0.74 + shade)
        case .directory, .file:
            let isFile = node.kind == .file
            let hue: Double
            var saturation: Double
            if byType {
                (hue, saturation) = tone(of: isFile ? node.category : node.dominantCategory)
            } else {
                // 0,9 de la vuelta: el último tono no se confunde con el primero.
                hue = (0.56 + min(max(position, 0), 1) * 0.9).truncatingRemainder(dividingBy: 1)
                saturation = 0.56
            }
            saturation = max(saturation * 0.55, saturation - depth * 0.035)
            var brightness = dark ? 0.80 + min(depth * 0.012, 0.08) : 0.90 + min(depth * 0.01, 0.07)
            if isFile {
                saturation *= byType ? 0.75 : 0.42
                brightness = min(1, brightness + (dark ? -0.06 : 0.03))
            }
            return Color(hue: hue, saturation: saturation, brightness: brightness)
        }
    }

    /// Color de una categoría tal como se ve en el primer anillo (para la leyenda).
    static func color(for category: FileCategory, dark: Bool) -> Color {
        let (hue, saturation) = tone(of: category)
        return Color(hue: hue, saturation: saturation, brightness: dark ? 0.80 : 0.90)
    }

    private static func tone(of category: FileCategory) -> (hue: Double, saturation: Double) {
        switch category {
        case .video: (0.97, 0.52)
        case .images: (0.07, 0.58)
        case .audio: (0.79, 0.45)
        case .documents: (0.58, 0.50)
        case .archives: (0.14, 0.60)
        case .apps: (0.48, 0.50)
        case .developer: (0.32, 0.48)
        case .caches: (0.62, 0.18)
        case .other: (0.08, 0.07)
        }
    }
}
