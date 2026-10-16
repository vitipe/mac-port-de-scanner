#if DEBUG
import AppKit
import ScannerCore

/// Solo en debug: guarda una captura de la ventana cuando termina el escaneo.
///   SCANNER_SNAPSHOT=/ruta.png          dónde guardarla
///   SCANNER_SNAPSHOT_HOVER=<anillo>     simula el cursor sobre el primer arco de ese anillo
///   SCANNER_APPEARANCE=dark|light
///   SCANNER_SNAPSHOT_QUIT=1             cerrar después
extension AppDelegate {
    func scheduleDebugSnapshot() {
        let env = ProcessInfo.processInfo.environment
        if let appearance = env["SCANNER_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        guard let path = env["SCANNER_SNAPSHOT"] else { return }
        Task { @MainActor in
            while session.scan != nil || session.focus == nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .seconds(1))
            session.setHover(nil)
            if let ring = env["SCANNER_SNAPSHOT_HOVER"].flatMap(Int.init), let focus = session.focus {
                let layout = SunburstLayout(focus: focus, innerRadius: 100, ringWidth: 30, ringCount: 10)
                if let arc = layout.rings[ring].first { session.setHover(.arc(arc)) }
            }
            try? await Task.sleep(for: .milliseconds(600))
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
