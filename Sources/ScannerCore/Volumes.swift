import Foundation

public struct VolumeInfo: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let totalCapacity: Int64
    /// Incluye el espacio purgeable, como lo muestra Finder.
    public let availableCapacity: Int64
    public let isRoot: Bool
    public let isInternal: Bool

    public var id: URL { url }
    public var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

    /// En el disco de arranque se escanea el volumen de datos: el de sistema es de
    /// solo lectura y los firmlinks (`/Users`, `/Applications`…) ya apuntan al de datos.
    public var scanPath: String {
        if isRoot, FileManager.default.fileExists(atPath: Volumes.dataVolumePath) {
            return Volumes.dataVolumePath
        }
        return url.path
    }
}

public enum Volumes {
    static let dataVolumePath = "/System/Volumes/Data"

    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
        .volumeIsRootFileSystemKey,
        .volumeIsBrowsableKey,
        .volumeIsInternalKey,
    ]

    /// Volúmenes visibles, con el de arranque primero.
    public static func mounted() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap(info(for:)).sorted {
            if $0.isRoot != $1.isRoot { return $0.isRoot }
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Datos actualizados del volumen montado en `url`.
    public static func info(for url: URL) -> VolumeInfo? {
        // URL nueva para no leer valores cacheados.
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        guard let values = try? fresh.resourceValues(forKeys: Set(keys)),
              values.volumeIsBrowsable != false,
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeInfo(
            url: fresh,
            name: values.volumeLocalizedName ?? fresh.lastPathComponent,
            totalCapacity: Int64(total),
            availableCapacity: available,
            isRoot: values.volumeIsRootFileSystem ?? (fresh.path == "/"),
            isInternal: values.volumeIsInternal ?? false
        )
    }
}
