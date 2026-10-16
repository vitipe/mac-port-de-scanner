import Foundation

/// Un archivo o carpeta del árbol escaneado. `size` es espacio ocupado en disco
/// (bloques asignados), no el tamaño lógico, igual que en el Scanner original.
///
/// `DiskScanner` arma el árbol desde varios hilos; una vez terminado, solo se
/// lee y modifica desde el hilo principal.
///
/// Un disco puede tener millones de nodos, así que el orden de los campos importa:
/// los chicos van al final para que la instancia ocupe 80 bytes.
public final class FileNode: Identifiable, @unchecked Sendable {
    public enum Kind: Sendable {
        case directory
        case file
        /// Espacio libre del volumen (nodo sintético).
        case free
        /// Usado según el sistema pero fuera del escaneo (nodo sintético). Puede tener
        /// hijos sintéticos que lo desglosan.
        case other
    }

    public internal(set) var name: String
    public internal(set) unowned(unsafe) var parent: FileNode?
    public internal(set) var size: Int64
    /// Ordenados de mayor a menor; los nodos sintéticos van al final.
    public internal(set) var children: [FileNode] = []
    /// Solo en carpetas: bytes por categoría (índice `FileCategory.rawValue`).
    public internal(set) var categorySizes: [Int64]?
    private var rootPaths: RootPaths?
    private var storedFileCount: Int32
    public let kind: Kind
    /// En archivos, su categoría.
    public internal(set) var category: FileCategory = .other
    /// No se pudo leer el contenido (permisos).
    public internal(set) var isInaccessible = false

    /// Solo los usa la raíz del árbol.
    private final class RootPaths {
        let path: String
        let display: String

        init(path: String, display: String) {
            self.path = path
            self.display = display
        }
    }

    public init(name: String, kind: Kind, size: Int64, fileCount: Int = 0) {
        self.name = name
        self.kind = kind
        self.size = size
        self.storedFileCount = Int32(clamping: fileCount)
    }

    public var id: ObjectIdentifier { ObjectIdentifier(self) }
    public var fileCount: Int { Int(storedFileCount) }
    public var isDirectory: Bool { kind == .directory }
    public var isSynthetic: Bool { kind == .free || kind == .other }

    /// La categoría que más ocupa: la propia en archivos, la mayoritaria en carpetas.
    public var dominantCategory: FileCategory {
        guard let sizes = categorySizes else { return category }
        var best = FileCategory.other
        var bestSize: Int64 = 0
        for (index, size) in sizes.enumerated() where size > bestSize {
            best = FileCategory(rawValue: UInt8(index)) ?? .other
            bestSize = size
        }
        return best
    }

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

    /// Los `limit` archivos más grandes dentro de este nodo, de mayor a menor.
    public func largestFiles(limit: Int) -> [FileNode] {
        guard limit > 0 else { return [] }
        var result: [FileNode] = []
        var stack = [self]
        // `result` se mantiene ordenado de mayor a menor; solo se inserta lo que entra.
        while let node = stack.popLast() {
            for child in node.children {
                switch child.kind {
                case .directory:
                    stack.append(child)
                case .file:
                    if result.count == limit, let last = result.last, child.size <= last.size { continue }
                    let index = result.firstIndex { $0.size < child.size } ?? result.count
                    result.insert(child, at: index)
                    if result.count > limit { result.removeLast() }
                case .free, .other:
                    break
                }
            }
        }
        return result
    }

    /// Ruta real en disco.
    public var path: String { resolvedPath(display: false) }

    /// Ruta para mostrar. En el disco de arranque se escanea `/System/Volumes/Data`
    /// pero se muestra como `/`.
    public var displayPath: String { resolvedPath(display: true) }

    func setBasePath(_ path: String, display: String) {
        rootPaths = RootPaths(path: path, display: display)
    }

    private func resolvedPath(display: Bool) -> String {
        var names: [String] = []
        var node = self
        while let parent = node.parent {
            names.append(node.name)
            node = parent
        }
        var result = (display ? node.rootPaths?.display : node.rootPaths?.path) ?? node.name
        for name in names.reversed() {
            if !result.hasSuffix("/") { result += "/" }
            result += name
        }
        return result
    }

    /// Busca un descendiente por ruta, real o de las que se muestran.
    /// Solo tiene sentido llamarlo sobre la raíz.
    public func descendant(atPath path: String) -> FileNode? {
        let relative = [rootPaths?.path, rootPaths?.display].lazy.compactMap { base -> Substring? in
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

    // MARK: - Armado (DiskScanner)

    func setFileCount(_ count: Int) {
        storedFileCount = Int32(clamping: count)
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

    /// Suma (`sign` = 1) o resta (`sign` = -1) el contenido de `node` en este nodo
    /// y sus ancestros: tamaño, archivos y bytes por categoría.
    private func propagate(_ node: FileNode, sign: Int64) {
        var current: FileNode? = self
        while let target = current {
            target.size += sign * node.size
            if !node.isSynthetic {
                target.storedFileCount += Int32(sign) * node.storedFileCount
                if target.categorySizes != nil {
                    if let sizes = node.categorySizes {
                        for index in sizes.indices { target.categorySizes![index] += sign * sizes[index] }
                    } else if node.kind == .file {
                        target.categorySizes![Int(node.category.rawValue)] += sign * node.size
                    }
                }
            }
            current = target.parent
        }
    }

    /// Agrega un nodo sintético (libre, sistema) al final, sin contarlo como archivo.
    public func appendSynthetic(_ node: FileNode) {
        node.parent = self
        children.append(node)
        children.sort(by: Self.ordered)
        propagate(node, sign: 1)
    }

    /// Quita los nodos sintéticos agregados con `appendSynthetic`.
    public func removeSyntheticChildren() {
        for child in children where child.isSynthetic {
            propagate(child, sign: -1)
            child.parent = nil
        }
        children.removeAll { $0.isSynthetic }
    }

    public func removeFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        parent.propagate(self, sign: -1)
        self.parent = nil
    }

    /// Vacía la carpeta, por ejemplo la Papelera después de vaciarla.
    public func removeAllChildren() {
        for child in children {
            propagate(child, sign: -1)
            child.parent = nil
        }
        children = []
    }

    public func insert(_ child: FileNode, renamedTo newName: String? = nil) {
        if let newName { child.name = newName }
        child.parent = self
        children.append(child)
        children.sort(by: Self.ordered)
        propagate(child, sign: 1)
    }

    public func replace(_ old: FileNode, with new: FileNode) {
        guard let index = children.firstIndex(where: { $0 === old }) else { return }
        new.name = old.name
        new.parent = self
        children[index] = new
        children.sort(by: Self.ordered)
        old.parent = nil
        propagate(old, sign: -1)
        propagate(new, sign: 1)
    }

    public func rename(_ newName: String) {
        name = newName
    }
}
