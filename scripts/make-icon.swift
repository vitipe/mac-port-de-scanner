// Dibuja el ícono de la app (un pequeño gráfico de anillos) en un PNG de 1024×1024.
// Uso: make-icon <salida.png>
import AppKit

let size = 1024.0
let output = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let context = NSGraphicsContext.current?.cgContext else { return false }

    // Fondo: squircle claro según la grilla de íconos de macOS (824 pt centrados).
    let inset = (size - 824) / 2
    let tile = CGRect(x: inset, y: inset, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    context.addPath(tilePath)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor(white: 1, alpha: 1).cgColor, NSColor(white: 0.93, alpha: 1).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    context.restoreGState()

    // Anillos: fracciones de cada nivel (en vueltas), con el mismo arcoíris suave de la app.
    let center = CGPoint(x: size / 2, y: size / 2)
    let inner = 96.0
    let ring = 78.0
    let gap = 5.0
    let levels: [[Double]] = [
        [0.34, 0.22, 0.16, 0.12, 0.08],
        [0.20, 0.09, 0.13, 0.06, 0.10, 0.07, 0.05],
        [0.12, 0.05, 0.07, 0.09, 0.04, 0.05],
    ]

    func color(at turn: Double, depth: Int) -> NSColor {
        let hue = (turn + 0.56).truncatingRemainder(dividingBy: 1)
        let saturation = 0.52 - Double(depth) * 0.05
        return NSColor(hue: hue, saturation: saturation, brightness: 0.94, alpha: 1)
    }

    for (depth, fractions) in levels.enumerated() {
        let r0 = inner + Double(depth) * ring + gap
        let r1 = r0 + ring - gap
        var turn = 0.0
        for fraction in fractions {
            // 0 arriba, sentido horario. En CoreGraphics (y hacia arriba) el ángulo crece antihorario.
            let a0 = .pi / 2 - (turn * 2 * .pi) - gap / r0
            let a1 = .pi / 2 - ((turn + fraction) * 2 * .pi) + gap / r0
            let path = CGMutablePath()
            path.addArc(center: center, radius: r1, startAngle: a0, endAngle: a1, clockwise: true)
            path.addArc(center: center, radius: r0, startAngle: a1, endAngle: a0, clockwise: false)
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(color(at: turn + fraction / 2, depth: depth).cgColor)
            context.fillPath()
            turn += fraction
        }
    }

    // Disco central.
    context.addEllipse(in: CGRect(x: center.x - inner + gap, y: center.y - inner + gap, width: (inner - gap) * 2, height: (inner - gap) * 2))
    context.setFillColor(NSColor(white: 0.90, alpha: 1).cgColor)
    context.fillPath()
    return true
}

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("No se pudo generar el PNG\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output))
