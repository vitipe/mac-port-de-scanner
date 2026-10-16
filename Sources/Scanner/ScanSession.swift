import AppKit
import ScannerCore
import SwiftUI

enum Source: Hashable {
    case volume(URL)
    case folder(URL)
    case trash
}

struct ScanStatus {
    /// `false` cuando se re-escanea solo una carpeta dentro del árbol.
    var isFull: Bool
    var files = 0
    var bytes: Int64 = 0
    /// Cuánto se espera encontrar, para mostrar el avance real (solo volúmenes).
    var expectedBytes: Int64?
    var currentPath = ""
}

enum ChartHover: Equatable {
    case center
    case arc(SunburstArc)

    var arc: SunburstArc? {
        if case .arc(let arc) = self { arc } else { nil }
    }
}

/// Animación de zoom entre dos carpetas (normalmente una dentro de la otra).
struct ZoomTransition: Equatable {
    static let duration = 0.42

    let from: FileNode
    let to: FileNode
    let start: Date

    static func == (a: ZoomTransition, b: ZoomTransition) -> Bool {
        a.from === b.from && a.to === b.to && a.start == b.start
    }
}

struct TrashState {
    /// `nil` si no se pudo leer (falta Acceso total al disco).
    var size: Int64?
    var isEmpty = true
    var isEmptying = false
}

@Observable @MainActor
final class ScanSession {
    private(set) var volumes: [VolumeInfo] = []
    private(set) var recentFolders: [URL] = []
    private(set) var source: Source?
    private(set) var root: FileNode?
    private(set) var focus: FileNode?
    private(set) var history: [FileNode] = []
    private(set) var hover: ChartHover?
    private(set) var zoomTransition: ZoomTransition?
    private(set) var scan: ScanStatus?
    private(set) var inaccessibleCount = 0
    /// Cambia cada vez que se modifica el árbol, para recalcular el gráfico.
    private(set) var treeVersion = 0
    /// Espacio purgeable incluido en "Libre".
    private(set) var purgeable: Int64 = 0
    var trash = TrashState()
    /// Resalta en el gráfico una categoría (al pasar por la leyenda).
    var highlightedCategory: FileCategory?
    var pendingTrash: FileNode?
    var confirmingEmptyTrash = false
    var errorMessage: String?

    var colorByType: Bool {
        didSet { UserDefaults.standard.set(colorByType, forKey: Keys.colorByType) }
    }

    var showsInspector: Bool {
        didSet { UserDefaults.standard.set(showsInspector, forKey: Keys.showsInspector) }
    }

    @ObservationIgnored private var currentProgress: ScanProgress?
    @ObservationIgnored private var lastActivation = Date.distantPast
    @ObservationIgnored private var layoutCache: [LayoutKey: SunburstLayout] = [:]
    @ObservationIgnored private var largestFilesCache: (key: LayoutKey, files: [FileNode])?
    @ObservationIgnored private var notes: [ObjectIdentifier: String] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored var trashWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored var trashRefreshInFlight = false
    @ObservationIgnored var trashRefreshAgain = false
    #if DEBUG
    /// Congela la animación de zoom en este punto (0…1) para capturas.
    @ObservationIgnored var debugFrozenZoomProgress: Double?
    #endif

    private enum Keys {
        static let recentFolders = "recentFolders"
        static let colorByType = "colorByType"
        static let showsInspector = "showsInspector"
    }

    init() {
        let defaults = UserDefaults.standard
        recentFolders = (defaults.stringArray(forKey: Keys.recentFolders) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        colorByType = defaults.bool(forKey: Keys.colorByType)
        showsInspector = defaults.object(forKey: Keys.showsInspector) as? Bool ?? true

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reloadVolumes()
                    self?.refreshTrash()
                }
            })
        }
        // Al volver a la app: el espacio libre y la Papelera pueden haber cambiado.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadVolumes()
                self?.refreshTrash()
            }
        })
    }

    // MARK: - Fuentes

    /// Al iniciar: la carpeta pedida o, si no hay, el disco de arranque.
    func start(initialFolder: URL?) {
        reloadVolumes()
        refreshTrash()
        if let initialFolder {
            open(initialFolder)
        } else if source == nil, let startup = volumes.first(where: \.isRoot) ?? volumes.first {
            activate(.volume(startup.url))
        }
    }

    func reloadVolumes() {
        volumes = Volumes.mounted()
        if case .volume(let url) = source, !volumes.contains(where: { $0.url == url }) {
            cancelScan()
            source = nil
            clearTree()
        }
    }

    /// Elegir una fuente; si ya estaba elegida, la vuelve a escanear (como el original).
    func activate(_ newSource: Source) {
        // Un mismo clic en la barra lateral llega dos veces (selección y gesto).
        guard newSource != source || Date.now.timeIntervalSince(lastActivation) > 0.5 else { return }
        lastActivation = .now
        if newSource == source {
            if scan == nil { rescanAll() }
            return
        }
        cancelScan()
        source = newSource
        clearTree()
        rescanAll()
    }

    private func clearTree() {
        root = nil
        focus = nil
        history = []
        hover = nil
        zoomTransition = nil
        inaccessibleCount = 0
        purgeable = 0
        notes = [:]
    }

    func open(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "“\(url.lastPathComponent)” no es una carpeta."
            return
        }
        reloadVolumes()
        if let volume = volumes.first(where: { $0.url.standardizedFileURL.path == url.path }) {
            activate(.volume(volume.url))
        } else if url == Self.userTrash {
            activate(.trash)
        } else {
            addRecent(url)
            activate(.folder(url))
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Escanear"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func removeRecent(_ url: URL) {
        recentFolders.removeAll { $0 == url }
        saveRecents()
        if source == .folder(url) {
            cancelScan()
            source = nil
            clearTree()
        }
    }

    private func addRecent(_ url: URL) {
        recentFolders.removeAll { $0 == url }
        recentFolders.insert(url, at: 0)
        recentFolders = Array(recentFolders.prefix(6))
        saveRecents()
    }

    private func saveRecents() {
        UserDefaults.standard.set(recentFolders.map(\.path), forKey: Keys.recentFolders)
    }

    // MARK: - Escaneo

    func rescanAll() {
        switch source {
        case .volume(let url):
            let volume = Volumes.info(for: url) ?? volumes.first { $0.url == url }
            runScan(path: volume?.scanPath ?? url.path, display: url.path, target: nil, volume: volume)
        case .folder(let url):
            runScan(path: url.path, display: url.path, target: nil, volume: nil)
        case .trash:
            runScan(path: Self.userTrash.path, display: Self.userTrash.path, target: nil, volume: nil)
        case nil:
            break
        }
    }

    func rescan(_ node: FileNode) {
        guard node.isDirectory else { return }
        if node === root || node.parent == nil {
            rescanAll()
        } else {
            runScan(path: node.path, display: node.displayPath, target: node, volume: nil)
        }
    }

    func rescanFocus() {
        if let focus { rescan(focus) } else { rescanAll() }
    }

    func cancelScan() {
        currentProgress?.cancel()
        currentProgress = nil
        scan = nil
    }

    private func runScan(path: String, display: String, target: FileNode?, volume: VolumeInfo?) {
        currentProgress?.cancel()
        let progress = ScanProgress()
        currentProgress = progress
        scan = ScanStatus(isFull: target == nil, currentPath: display)

        Task { [weak self] in
            while let self, self.currentProgress === progress {
                self.scan?.files = progress.fileCount
                self.scan?.bytes = progress.byteCount
                self.scan?.currentPath = Self.displayPath(progress.currentPath, real: path, display: display)
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // El uso por volumen (diskutil) da el total esperado y el desglose del disco.
            let container = volume.flatMap { _ in ContainerUsage.load(forPath: path) }
            if let volume {
                let expected = container?.scannedVolumeUsed ?? volume.usedCapacity
                Task { @MainActor in
                    if self?.currentProgress === progress { self?.scan?.expectedBytes = expected }
                }
            }
            let result = DiskScanner.scan(path: path, displayPath: display, progress: progress)
            Task { @MainActor in
                self?.finishScan(result, progress: progress, target: target, volume: volume, container: container)
            }
        }
    }

    private func finishScan(_ result: FileNode?, progress: ScanProgress, target: FileNode?,
                            volume: VolumeInfo?, container: ContainerUsage?) {
        guard progress === currentProgress else { return }
        currentProgress = nil
        scan = nil
        guard let result else { return }

        if let target {
            guard let parent = target.parent, target.root === root else { return }
            inaccessibleCount += progress.inaccessibleCount - target.inaccessibleCount
            parent.replace(target, with: result)
            if focus === target { focus = result }
            history = history.map { $0 === target ? result : $0 }
        } else {
            if let volume, let info = Volumes.info(for: volume.url) {
                result.rename(info.name)
                applyDiskNodes(to: result, info: info, container: container)
                if let index = volumes.firstIndex(where: { $0.url == info.url }) { volumes[index] = info }
            } else if source == .trash {
                result.rename("Papelera")
            }
            let previousFocus = focus?.path
            root = result
            focus = previousFocus.flatMap(result.descendant(atPath:)) ?? result
            history = []
            inaccessibleCount = progress.inaccessibleCount
        }
        hover = nil
        zoomTransition = nil
        treeVersion += 1
    }

    private static func displayPath(_ path: String, real: String, display: String) -> String {
        guard real != display, path.hasPrefix(real) else { return path }
        let rest = path.dropFirst(real.count)
        if display == "/" { return rest.isEmpty ? "/" : String(rest) }
        return display + rest
    }

    // MARK: - Disco: libre y "Sistema y otros"

    /// Agrega en la raíz de un volumen lo que el escaneo no ve: "Sistema y otros",
    /// desglosado por volumen APFS cuando se puede, y "Libre".
    private func applyDiskNodes(to root: FileNode, info: VolumeInfo, container: ContainerUsage?) {
        root.removeSyntheticChildren()
        notes = [:]
        let other = info.usedCapacity - root.size
        if other > 0 {
            var parts = container?.otherVolumeParts ?? []
            let known = parts.reduce(0) { $0 + $1.size }
            if known > other {
                // Lo purgeable se descuenta del usado: se reparte lo que hay.
                let scale = Double(other) / Double(known)
                parts = parts.map { ($0.name, Int64(Double($0.size) * scale)) }
            } else if known > 0 {
                parts.append(("Sin escanear", other - known))
            }
            let node = FileNode(name: "Sistema y otros", kind: .other, size: parts.isEmpty ? other : 0)
            notes[ObjectIdentifier(node)] = "Usado, pero fuera del escaneo"
            for part in parts where part.size > 0 {
                let child = FileNode(name: part.name, kind: .other, size: part.size)
                notes[ObjectIdentifier(child)] = Self.partNotes[part.name]
                node.appendSynthetic(child)
            }
            root.appendSynthetic(node)
        }
        let free = FileNode(name: "Libre", kind: .free, size: info.availableCapacity)
        purgeable = container.map { max(0, info.availableCapacity - $0.free) } ?? 0
        notes[ObjectIdentifier(free)] = purgeable > 0 ? "Incluye \(Format.bytes(purgeable)) purgeable" : "Disponible"
        root.appendSynthetic(free)
    }

    private static let partNotes = [
        "macOS": "Volumen del sistema",
        "Arranque": "Preboot, Recovery y actualizaciones",
        "Swap": "Memoria virtual",
        "Otros volúmenes": "Del mismo disco",
        "Sin escanear": "Sin acceso, snapshots, metadatos",
    ]

    /// Recalcula libre y "Sistema y otros" (por ejemplo, después de vaciar la Papelera).
    func refreshDiskNodes() {
        guard case .volume(let url) = source, let root, scan == nil else { return }
        let scanPath = Volumes.info(for: url)?.scanPath ?? url.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let container = ContainerUsage.load(forPath: scanPath)
            Task { @MainActor in
                guard let self, self.root === root, let info = Volumes.info(for: url) else { return }
                self.applyDiskNodes(to: root, info: info, container: container)
                self.treeVersion += 1
            }
        }
    }

    /// Explicación de un nodo sintético (libre, sistema…), para la barra y el panel.
    func note(for node: FileNode) -> String? {
        notes[ObjectIdentifier(node)]
    }

    // MARK: - Navegación

    var canGoBack: Bool { !history.isEmpty }
    var canGoUp: Bool { focus?.parent != nil }

    func zoom(to node: FileNode) {
        guard node.isDirectory, node !== focus, !node.children.isEmpty else { return }
        if let focus { history.append(focus) }
        setFocus(node)
    }

    func goUp() {
        guard let focus, let parent = focus.parent else { return }
        history.append(focus)
        setFocus(parent)
    }

    func goBack() {
        while let previous = history.popLast() {
            // Puede haber quedado afuera del árbol por un re-escaneo.
            if let root, previous.root === root {
                setFocus(previous)
                return
            }
        }
    }

    private func setFocus(_ node: FileNode) {
        hover = nil
        if let focus, focus !== node, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            zoomTransition = ZoomTransition(from: focus, to: node, start: .now)
        }
        focus = node
    }

    func endZoomTransition(_ transition: ZoomTransition) {
        #if DEBUG
        if debugFrozenZoomProgress != nil { return }
        #endif
        if zoomTransition == transition { zoomTransition = nil }
    }

    func setHover(_ newValue: ChartHover?) {
        if newValue != hover { hover = newValue }
    }

    /// Quita el hover solo si sigue siendo `arc` (al salir de una fila del panel).
    func clearHover(ifArc arc: SunburstArc) {
        if hover == .arc(arc) { hover = nil }
    }

    // MARK: - Gráfico

    private struct LayoutKey: Hashable {
        let focus: ObjectIdentifier
        let width: Int
        let height: Int
        let version: Int
    }

    func layout(for focus: FileNode, in size: CGSize) -> SunburstLayout {
        let key = LayoutKey(focus: ObjectIdentifier(focus), width: Int(size.width), height: Int(size.height), version: treeVersion)
        if let cached = layoutCache[key] { return cached }
        // Pocas entradas: la carpeta actual y, durante el zoom, la anterior.
        if layoutCache.count >= 6 { layoutCache.removeAll() }
        let radius = max(80, min(size.width, size.height) / 2 - 6)
        let inner = max(52, radius * 0.25)
        let rings = max(3, min(10, Int((radius - inner) / 27)))
        let layout = SunburstLayout(focus: focus, innerRadius: inner, ringWidth: (radius - inner) / Double(rings), ringCount: rings)
        layoutCache[key] = layout
        return layout
    }

    /// El último layout calculado para `focus`, para colorear fuera del gráfico igual que adentro.
    func cachedLayout(for focus: FileNode) -> SunburstLayout? {
        layoutCache.first { $0.key.focus == ObjectIdentifier(focus) && $0.key.version == treeVersion }?.value
    }

    var contentSpan: Double {
        focus.flatMap(cachedLayout(for:))?.contentSpan ?? 2 * .pi
    }

    func largestFiles(in node: FileNode) -> [FileNode] {
        let key = LayoutKey(focus: ObjectIdentifier(node), width: 0, height: 0, version: treeVersion)
        if let cache = largestFilesCache, cache.key == key { return cache.files }
        let files = node.largestFiles(limit: 50)
        largestFilesCache = (key, files)
        return files
    }

    // MARK: - Acciones sobre archivos

    func reveal(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    func openItem(_ node: FileNode) {
        NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
    }

    func copyPath(_ node: FileNode) {
        let display = node.displayPath
        let path = FileManager.default.fileExists(atPath: display) ? display : node.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func trash(_ node: FileNode) {
        pendingTrash = nil
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: &resulting)
        } catch {
            errorMessage = "No se pudo mover “\(node.name)” a la Papelera: \(error.localizedDescription)"
            return
        }
        node.removeFromParent()
        // Si la Papelera está dentro de lo escaneado, el elemento pasa a ella.
        if let url = resulting as URL?, let root,
           let trashFolder = root.descendant(atPath: url.deletingLastPathComponent().path) {
            trashFolder.insert(node, renamedTo: url.lastPathComponent)
        }
        treeDidChange()
        refreshTrash()
    }

    /// Después de cambiar el árbol sin re-escanear.
    func treeDidChange() {
        hover = nil
        treeVersion += 1
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
