import Foundation
import Synchronization

/// Progreso de un escaneo, legible desde cualquier hilo mientras corre.
public final class ScanProgress: Sendable {
    private let files = Atomic<Int>(0)
    private let bytes = Atomic<Int64>(0)
    private let inaccessible = Atomic<Int>(0)
    private let cancelled = Atomic<Bool>(false)
    private let current = Mutex<String>("")

    public init() {}

    public var fileCount: Int { files.load(ordering: .relaxed) }
    public var byteCount: Int64 { bytes.load(ordering: .relaxed) }
    /// Carpetas que no se pudieron leer por permisos.
    public var inaccessibleCount: Int { inaccessible.load(ordering: .relaxed) }
    public var currentPath: String { current.withLock { $0 } }
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    public func cancel() { cancelled.store(true, ordering: .relaxed) }

    func add(files fileDelta: Int, bytes byteDelta: Int64) {
        files.wrappingAdd(fileDelta, ordering: .relaxed)
        bytes.wrappingAdd(byteDelta, ordering: .relaxed)
    }

    func addInaccessible() { inaccessible.wrappingAdd(1, ordering: .relaxed) }

    func setCurrentPath(_ path: String) { current.withLock { $0 = path } }
}

/// Recorre el disco con llamadas POSIX (`readdir` + `fstatat`), mucho más rápido que
/// `FileManager` para millones de archivos. Cuenta bloques asignados, no sigue
/// symlinks, no cruza a otros volúmenes y cuenta una sola vez cada hardlink.
public enum DiskScanner {
    /// Hasta qué profundidad se reparten las subcarpetas entre hilos.
    static let parallelDepth = 6
    /// Corte de seguridad contra árboles patológicamente profundos.
    static let maxDepth = 512

    /// Escanea `path`. Devuelve `nil` si se canceló o la ruta no existe.
    public static func scan(path: String, displayPath: String? = nil, progress: ScanProgress) -> FileNode? {
        disableDatalessMaterialization
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let isDirectory = st.st_mode & S_IFMT == S_IFDIR
        let name = path == "/" ? "/" : (path as NSString).lastPathComponent
        let root = FileNode(
            name: name,
            kind: isDirectory ? .directory : .file,
            size: allocatedSize(st),
            fileCount: isDirectory ? 0 : 1
        )
        root.setBasePath(path, display: displayPath ?? path)
        if isDirectory {
            let context = Context(device: st.st_dev, progress: progress)
            scanDirectory(root, path: path, depth: 0, context: context)
        }
        return progress.isCancelled ? nil : root
    }

    // MARK: - Implementación

    private struct HardLink: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private final class Context: Sendable {
        let device: dev_t
        let progress: ScanProgress
        private let seenHardLinks = Mutex<Set<HardLink>>([])

        init(device: dev_t, progress: ScanProgress) {
            self.device = device
            self.progress = progress
        }

        /// `true` la primera vez que aparece este inodo.
        func firstSighting(_ st: stat) -> Bool {
            seenHardLinks.withLock { $0.insert(HardLink(device: st.st_dev, inode: st.st_ino)).inserted }
        }
    }

    /// Evita que leer carpetas de iCloud/File Provider dispare descargas.
    private static let disableDatalessMaterialization: Void = {
        _ = setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_PROCESS,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        )
    }()

    private static let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name)!

    private static func allocatedSize(_ st: stat) -> Int64 {
        Int64(st.st_blocks) * 512
    }

    private static func join(_ path: String, _ name: String) -> String {
        path.hasSuffix("/") ? path + name : path + "/" + name
    }

    private static func scanDirectory(_ node: FileNode, path: String, depth: Int, context: Context) {
        let progress = context.progress
        guard !progress.isCancelled, depth < maxDepth else { return }
        progress.setCurrentPath(path)

        guard let dir = opendir(path) else {
            if errno == EACCES || errno == EPERM {
                node.isInaccessible = true
                progress.addInaccessible()
            }
            return
        }
        let fd = dirfd(dir)

        var subdirectories: [FileNode] = []
        var unscannedDirectories: [FileNode] = []
        var files: [FileNode] = []
        var fileBytes: Int64 = 0
        var fileCount = 0
        var st = stat()

        while let entry = readdir(dir) {
            let cName = UnsafeRawPointer(entry).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)
            if cName[0] == 0x2E && (cName[1] == 0 || (cName[1] == 0x2E && cName[2] == 0)) { continue }
            guard fstatat(fd, cName, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }

            if st.st_mode & S_IFMT == S_IFDIR {
                // Otro volumen montado acá adentro: no se cruza.
                guard st.st_dev == context.device else { continue }
                let child = FileNode(name: String(cString: cName), kind: .directory, size: allocatedSize(st))
                if st.st_flags & UInt32(SF_DATALESS) != 0 {
                    unscannedDirectories.append(child)
                } else {
                    subdirectories.append(child)
                }
            } else {
                if st.st_nlink > 1, st.st_mode & S_IFMT == S_IFREG, !context.firstSighting(st) { continue }
                let size = allocatedSize(st)
                fileCount += 1
                fileBytes += size
                if size > 0 {
                    files.append(FileNode(name: String(cString: cName), kind: .file, size: size, fileCount: 1))
                }
            }
        }
        closedir(dir)

        let directories = subdirectories + unscannedDirectories
        progress.add(files: fileCount, bytes: fileBytes + directories.reduce(0) { $0 + $1.size })

        let scanList = subdirectories
        if depth < parallelDepth && scanList.count > 1 {
            DispatchQueue.concurrentPerform(iterations: scanList.count) { index in
                let child = scanList[index]
                scanDirectory(child, path: join(path, child.name), depth: depth + 1, context: context)
            }
        } else {
            for child in scanList {
                scanDirectory(child, path: join(path, child.name), depth: depth + 1, context: context)
            }
        }

        var totalSize = node.size + fileBytes
        var totalFiles = fileCount
        for directory in directories {
            totalSize += directory.size
            totalFiles += directory.fileCount
        }
        var children = directories + files
        for child in children { child.parent = node }
        children.sort(by: FileNode.ordered)
        node.children = children
        node.size = totalSize
        node.fileCount = totalFiles
    }
}
