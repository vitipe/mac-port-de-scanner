import AppKit
import ScannerCore
import SwiftUI

enum Source: Hashable {
    case volume(URL)
    case folder(URL)
}

struct ScanStatus {
    /// `false` cuando se re-escanea solo una carpeta dentro del árbol.
    var isFull: Bool
    var files = 0
    var bytes: Int64 = 0
    var currentPath = ""
}

enum ChartHover: Equatable {
    case center
    case arc(SunburstArc)

    var arc: SunburstArc? {
        if case .arc(let arc) = self { arc } else { nil }
    }
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
    private(set) var scan: ScanStatus?
    private(set) var inaccessibleCount = 0
    /// Cambia cada vez que se modifica el árbol, para recalcular el gráfico.
    private(set) var treeVersion = 0
    var pendingTrash: FileNode?
    var errorMessage: String?

    @ObservationIgnored private var currentProgress: ScanProgress?
    @ObservationIgnored private var lastActivation = Date.distantPast
    @ObservationIgnored private var layoutCache: (key: LayoutKey, layout: SunburstLayout)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let recentFoldersKey = "recentFolders"

    init() {
        recentFolders = (UserDefaults.standard.stringArray(forKey: Self.recentFoldersKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadVolumes() }
            })
        }
    }

    // MARK: - Fuentes

    /// Al iniciar: la carpeta pedida o, si no hay, el disco de arranque.
    func start(initialFolder: URL?) {
        reloadVolumes()
        if let initialFolder {
            open(initialFolder)
        } else if let startup = volumes.first(where: \.isRoot) ?? volumes.first {
            activate(.volume(startup.url))
        }
    }

    func reloadVolumes() {
        volumes = Volumes.mounted()
        if case .volume(let url) = source, !volumes.contains(where: { $0.url == url }) {
            cancelScan()
            source = nil
            root = nil
            focus = nil
            history = []
            hover = nil
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
        root = nil
        focus = nil
        history = []
        hover = nil
        inaccessibleCount = 0
        rescanAll()
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
            root = nil
            focus = nil
            history = []
        }
    }

    private func addRecent(_ url: URL) {
        recentFolders.removeAll { $0 == url }
        recentFolders.insert(url, at: 0)
        recentFolders = Array(recentFolders.prefix(6))
        saveRecents()
    }

    private func saveRecents() {
        UserDefaults.standard.set(recentFolders.map(\.path), forKey: Self.recentFoldersKey)
    }

    // MARK: - Escaneo

    func rescanAll() {
        switch source {
        case .volume(let url):
            let volume = volumes.first { $0.url == url } ?? Volumes.info(for: url)
            runScan(path: volume?.scanPath ?? url.path, display: url.path, target: nil)
        case .folder(let url):
            runScan(path: url.path, display: url.path, target: nil)
        case nil:
            break
        }
    }

    func rescan(_ node: FileNode) {
        guard node.isDirectory else { return }
        if node === root || node.parent == nil {
            rescanAll()
        } else {
            runScan(path: node.path, display: node.displayPath, target: node)
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

    private func runScan(path: String, display: String, target: FileNode?) {
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
            let result = DiskScanner.scan(path: path, displayPath: display, progress: progress)
            Task { @MainActor in
                self?.finishScan(result, progress: progress, target: target)
            }
        }
    }

    private func finishScan(_ result: FileNode?, progress: ScanProgress, target: FileNode?) {
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
            if case .volume(let url) = source, let info = Volumes.info(for: url) {
                result.rename(info.name)
                let other = info.usedCapacity - result.size
                if other > 0 {
                    result.appendSynthetic(FileNode(name: "Sistema y otros", kind: .other, size: other))
                }
                result.appendSynthetic(FileNode(name: "Libre", kind: .free, size: info.availableCapacity))
                if let index = volumes.firstIndex(where: { $0.url == url }) { volumes[index] = info }
            }
            let previousFocus = focus?.path
            root = result
            focus = previousFocus.flatMap(result.descendant(atPath:)) ?? result
            history = []
            inaccessibleCount = progress.inaccessibleCount
        }
        hover = nil
        treeVersion += 1
    }

    private static func displayPath(_ path: String, real: String, display: String) -> String {
        guard real != display, path.hasPrefix(real) else { return path }
        let rest = path.dropFirst(real.count)
        if display == "/" { return rest.isEmpty ? "/" : String(rest) }
        return display + rest
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
        withAnimation(.smooth(duration: 0.3)) { focus = node }
    }

    func setHover(_ newValue: ChartHover?) {
        if newValue != hover { hover = newValue }
    }

    // MARK: - Gráfico

    private struct LayoutKey: Equatable {
        let focus: ObjectIdentifier
        let width: Int
        let height: Int
        let version: Int
    }

    func layout(for focus: FileNode, in size: CGSize) -> SunburstLayout {
        let key = LayoutKey(focus: ObjectIdentifier(focus), width: Int(size.width), height: Int(size.height), version: treeVersion)
        if let cache = layoutCache, cache.key == key { return cache.layout }
        let radius = max(80, min(size.width, size.height) / 2 - 6)
        let inner = max(52, radius * 0.25)
        let rings = max(3, min(10, Int((radius - inner) / 27)))
        let layout = SunburstLayout(focus: focus, innerRadius: inner, ringWidth: (radius - inner) / Double(rings), ringCount: rings)
        layoutCache = (key, layout)
        return layout
    }

    /// Para colorear fuera del gráfico igual que adentro.
    var contentSpan: Double { layoutCache?.layout.contentSpan ?? 2 * .pi }

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
        hover = nil
        node.removeFromParent()
        // Si la Papelera está dentro de lo escaneado, el elemento pasa a ella.
        if let url = resulting as URL?, let root,
           let trashFolder = root.descendant(atPath: url.deletingLastPathComponent().path) {
            trashFolder.insert(node, renamedTo: url.lastPathComponent)
        }
        treeVersion += 1
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
