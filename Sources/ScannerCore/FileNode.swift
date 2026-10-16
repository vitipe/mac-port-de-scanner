import Foundation

/// Un archivo o carpeta del árbol escaneado. `size` es espacio ocupado en disco
/// (bloques asignados), no el tamaño lógico, igual que en el Scanner original.
///
/// `DiskScanner` arma el árbol desde varios hilos; una vez terminado, solo se
/// lee y modifica desde el hilo principal.
public final class FileNode: @unchecked Sendable {
    public enum Kind: Sendable {
        case directory
        case file
        /// Espacio libre del volumen (nodo sintético).
        case free
        /// Usado según el sistema pero fuera del escaneo: sistema, snapshots, purgeable (nodo sintético).
        case other
    }

    public internal(set) var name: String
    public let kind: Kind
    public internal(set) unowned(unsafe) var parent: FileNode?
    public internal(set) var size: Int64
    public internal(set) var fileCount: Int
    /// Ordenados de mayor a menor; los nodos sintéticos van al final.
    public internal(set) var children: [FileNode] = []
    /// No se pudo leer el contenido (permisos).
    public internal(set) var isInaccessible = false

    // Solo los usa la raíz del árbol.
    private var basePath: String?
    private var baseDisplayPath: String?

    public init(name: String, kind: Kind, size: Int64, fileCount: Int = 0) {
        self.name = name
        self.kind = kind
        self.size = size
        self.fileCount = fileCount
    }

    public var isDirectory: Bool { kind == .directory }
    public var isSynthetic: Bool { kind == .free || kind == .other }

    public var root: FileNode {
        var node = self
        while let parent = node.parent { node = parent }
        return node
    }

    /// `true` si es `ancestor` o está dentro de él.
    public func isDescendant(of ancestor: FileNode) -> Bool {
        var node: FileNode? = self
        while let current = node {
            if current === ancestor { return true }
            node = current.parent
        }
        return false
    }

    /// Carpetas sin acceso dentro de este nodo, incluido él mismo.
    public var inaccessibleCount: Int {
        var count = 0
        var stack = [self]
        while let node = stack.popLast() {
            if node.isInaccessible { count += 1 }
            stack.append(contentsOf: node.children.lazy.filter(\.isDirectory))
        }
        return count
    }

    /// Ruta real en disco.
    public var path: String { resolvedPath(display: false) }

    /// Ruta para mostrar. En el disco de arranque se escanea `/System/Volumes/Data`
    /// pero se muestra como `/`.
    public var displayPath: String { resolvedPath(display: true) }

    func setBasePath(_ path: String, display: String) {
        basePath = path
        baseDisplayPath = display
    }

    private func resolvedPath(display: Bool) -> String {
        var names: [String] = []
        var node = self
        while let parent = node.parent {
            names.append(node.name)
            node = parent
        }
        var result = (display ? node.baseDisplayPath : node.basePath) ?? node.name
        for name in names.reversed() {
            if !result.hasSuffix("/") { result += "/" }
            result += name
        }
        return result
    }

    /// Busca un descendiente por ruta, real o de las que se muestran.
    /// Solo tiene sentido llamarlo sobre la raíz.
    public func descendant(atPath path: String) -> FileNode? {
        let relative = [basePath, baseDisplayPath].lazy.compactMap { base -> Substring? in
            guard let base else { return nil }
            if path == base { return "" }
            let prefix = base.hasSuffix("/") ? base : base + "/"
            return path.hasPrefix(prefix) ? path.dropFirst(prefix.count) : nil
        }.first
        guard let relative else { return nil }
        var node = self
        for component in relative.split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == component }) else { return nil }
            node = next
        }
        return node
    }

    // MARK: - Cambios sobre el árbol (hilo principal)

    static func ordered(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.sortGroup != b.sortGroup { return a.sortGroup < b.sortGroup }
        return a.size > b.size
    }

    private var sortGroup: Int {
        switch kind {
        case .directory, .file: 0
        case .other: 1
        case .free: 2
        }
    }

    private func adjustUpward(size delta: Int64, files: Int) {
        var node: FileNode? = self
        while let current = node {
            current.size += delta
            current.fileCount += files
            node = current.parent
        }
    }

    /// Agrega un nodo sintético (libre, sistema) al final, sin contarlo como archivo.
    public func appendSynthetic(_ node: FileNode) {
        node.parent = self
        children.append(node)
        children.sort(by: Self.ordered)
        adjustUpward(size: node.size, files: 0)
    }

    public func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        parent.adjustUpward(size: -size, files: -fileCount)
        self.parent = nil
    }

    public func insert(_ child: FileNode, renamedTo newName: String? = nil) {
        if let newName { child.name = newName }
        child.parent = self
        children.append(child)
        children.sort(by: Self.ordered)
        adjustUpward(size: child.size, files: child.fileCount)
    }

    public func replace(_ old: FileNode, with new: FileNode) {
        guard let index = children.firstIndex(where: { $0 === old }) else { return }
        new.name = old.name
        new.parent = self
        children[index] = new
        children.sort(by: Self.ordered)
        old.parent = nil
        adjustUpward(size: new.size - old.size, files: new.fileCount - old.fileCount)
    }

    public func rename(_ newName: String) {
        name = newName
    }
}
