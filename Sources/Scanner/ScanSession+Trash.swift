import AppKit
import ScannerCore

/// La Papelera en la barra lateral: cuánto ocupa y vaciarla (como el "Empty Recycle
/// Bin" del original).
extension ScanSession {
    nonisolated static let userTrash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")

    /// La Papelera de inicio y las de los otros volúmenes montados.
    private var trashDirectories: [URL] {
        var urls = [Self.userTrash]
        for volume in volumes where !volume.isRoot {
            if let url = try? FileManager.default.url(
                for: .trashDirectory, in: .userDomainMask, appropriateFor: volume.url, create: false
            ) {
                urls.append(url)
            }
        }
        return urls
    }

    func refreshTrash() {
        guard !trashRefreshInFlight else {
            trashRefreshAgain = true
            return
        }
        trashRefreshInFlight = true
        let directories = trashDirectories
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let measured = Self.measureTrash(directories)
            Task { @MainActor in
                guard let self else { return }
                self.trash.size = measured.size
                self.trash.isEmpty = measured.isEmpty
                self.trashRefreshInFlight = false
                self.watchTrash()
                if self.trashRefreshAgain {
                    self.trashRefreshAgain = false
                    self.refreshTrash()
                }
            }
        }
    }

    nonisolated private static func measureTrash(_ directories: [URL]) -> (size: Int64?, isEmpty: Bool) {
        var total: Int64 = 0
        var isEmpty = true
        for (index, url) in directories.enumerated() {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                // La de inicio existe siempre: si no se puede leer, falta Acceso total al disco.
                if index == 0 { return (nil, false) }
                continue
            }
            if entries.contains(where: { $0 != ".DS_Store" }) { isEmpty = false }
            if let node = DiskScanner.scan(path: url.path, progress: ScanProgress()) {
                total += node.children.reduce(0) { $0 + $1.size }
            }
        }
        return (total, isEmpty)
    }

    /// Avisa cuando cambia la Papelera de inicio, también si se borra desde Finder.
    private func watchTrash() {
        guard trashWatcher == nil else { return }
        let descriptor = Darwin.open(Self.userTrash.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main
        )
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refreshTrash() }
        }
        watcher.setCancelHandler { close(descriptor) }
        watcher.resume()
        trashWatcher = watcher
    }

    /// Le pide a Finder que vacíe todas las papeleras, igual que el menú de Finder.
    func emptyTrash() {
        guard !trash.isEmptying else { return }
        trash.isEmptying = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { [weak self] process in
            let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let succeeded = process.terminationStatus == 0
            Task { @MainActor in self?.trashEmptied(succeeded: succeeded, output: output) }
        }
        do {
            try process.run()
        } catch {
            trash.isEmptying = false
            errorMessage = "No se pudo vaciar la Papelera: \(error.localizedDescription)"
        }
    }

    private func trashEmptied(succeeded: Bool, output: String) {
        trash.isEmptying = false
        guard succeeded else {
            // -1743: el usuario no autorizó que Scanner controle Finder.
            errorMessage = output.contains("-1743")
                ? "Scanner necesita permiso para pedirle a Finder que vacíe la Papelera. Activalo en Ajustes del Sistema › Privacidad y seguridad › Automatización."
                : "No se pudo vaciar la Papelera."
            return
        }
        // Lo que había en las papeleras ya no ocupa lugar en el gráfico.
        if let root, scan == nil {
            for url in trashDirectories {
                root.descendant(atPath: url.path)?.removeAllChildren()
            }
            treeDidChange()
        }
        reloadVolumes()
        refreshTrash()
        refreshDiskNodes()
    }
}
