#if DEBUG
import AppKit
import ScannerCore

/// Solo en debug: guarda una captura de la ventana cuando termina el escaneo.
///   SCANNER_SNAPSHOT=/ruta.png          dónde guardarla
///   SCANNER_SNAPSHOT_HOVER=<anillo>     simula el cursor sobre el primer arco de ese anillo
///   SCANNER_SNAPSHOT_HOVER_NAME=<nombre> o sobre el arco con ese nombre
///   SCANNER_SNAPSHOT_ZOOM_T=<0…1>       congela la animación de zoom hacia la primera subcarpeta
///   SCANNER_SNAPSHOT_FOCUS=<ruta>       enfoca esa carpeta antes de capturar
///   SCANNER_COLOR_BY_TYPE=0|1, SCANNER_INSPECTOR=0|1, SCANNER_APPEARANCE=dark|light
///   SCANNER_SNAPSHOT_QUIT=1             cerrar después
extension AppDelegate {
    func scheduleDebugSnapshot() {
        let env = ProcessInfo.processInfo.environment
        if let appearance = env["SCANNER_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let value = env["SCANNER_COLOR_BY_TYPE"] { session.colorByType = value == "1" }
        if let value = env["SCANNER_INSPECTOR"] { session.showsInspector = value == "1" }
        guard let path = env["SCANNER_SNAPSHOT"] else { return }
        Task { @MainActor in
            while session.scan != nil || session.focus == nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .seconds(1))
            session.setHover(nil)
            if let focusPath = env["SCANNER_SNAPSHOT_FOCUS"], let node = session.root?.descendant(atPath: focusPath) {
                session.zoom(to: node)
                try? await Task.sleep(for: .seconds(0.6))
            }
            if let ring = env["SCANNER_SNAPSHOT_HOVER"].flatMap(Int.init), let focus = session.focus,
               let layout = session.cachedLayout(for: focus), ring < layout.rings.count,
               let arc = layout.rings[ring].first {
                session.setHover(.arc(arc))
            }
            if let name = env["SCANNER_SNAPSHOT_HOVER_NAME"], let focus = session.focus,
               let layout = session.cachedLayout(for: focus),
               let arc = layout.rings.joined().first(where: { $0.node?.name == name }) {
                session.setHover(.arc(arc))
            }
            if let t = env["SCANNER_SNAPSHOT_ZOOM_T"].flatMap(Double.init), let focus = session.focus,
               let child = focus.children.first(where: { $0.isDirectory && !$0.children.isEmpty }) {
                session.debugFrozenZoomProgress = t
                session.zoom(to: child)
            }
            try? await Task.sleep(for: .milliseconds(700))
            if let view = window?.contentView?.superview ?? window?.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            if env["SCANNER_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
        }
    }
}
#endif
