import Foundation

/// Uso de un contenedor APFS por volumen, para desglosar "Sistema y otros":
/// lo que macOS cuenta como usado pero el escaneo no alcanza.
public struct ContainerUsage: Sendable {
    public struct Volume: Sendable {
        public let device: String
        public let name: String
        public let roles: [String]
        public let used: Int64
    }

    public let capacity: Int64
    /// Libre real del contenedor, sin contar el espacio purgeable.
    public let free: Int64
    public let volumes: [Volume]
    /// El volumen que se escaneó (en el disco de arranque, el de datos).
    public let scannedDevice: String

    /// Lee el contenedor del volumen montado en `path` con `diskutil`.
    /// `nil` si no es APFS o no se pudo leer.
    public static func load(forPath path: String) -> ContainerUsage? {
        guard let info = plist("info", "-plist", path),
              let device = info["DeviceIdentifier"] as? String,
              let container = info["APFSContainerReference"] as? String,
              let list = plist("apfs", "list", "-plist", container),
              let containers = list["Containers"] as? [[String: Any]],
              let entry = containers.first(where: { $0["ContainerReference"] as? String == container })
        else { return nil }

        let volumes = (entry["Volumes"] as? [[String: Any]] ?? []).compactMap { volume -> Volume? in
            guard let id = volume["DeviceIdentifier"] as? String else { return nil }
            return Volume(
                device: id,
                name: volume["Name"] as? String ?? id,
                roles: volume["Roles"] as? [String] ?? [],
                used: (volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
            )
        }
        return ContainerUsage(
            capacity: (entry["CapacityCeiling"] as? NSNumber)?.int64Value ?? 0,
            free: (entry["CapacityFree"] as? NSNumber)?.int64Value ?? 0,
            volumes: volumes,
            // En el disco de arranque `/` es un snapshot del sistema (disk3s1s1).
            scannedDevice: device
        )
    }

    /// Lo que ocupa el volumen escaneado según APFS: el total esperado del escaneo.
    public var scannedVolumeUsed: Int64? {
        volumes.first(where: isScanned)?.used
    }

    /// Partes conocidas de lo que ocupan los otros volúmenes del contenedor.
    public var otherVolumeParts: [(name: String, size: Int64)] {
        var system: Int64 = 0
        var swap: Int64 = 0
        var boot: Int64 = 0
        var others: Int64 = 0
        for volume in volumes where !isScanned(volume) {
            let roles = Set(volume.roles)
            if roles.contains("System") {
                system += volume.used
            } else if roles.contains("VM") {
                swap += volume.used
            } else if !roles.isDisjoint(with: ["Preboot", "Recovery", "Update", "xART", "Hardware", "Baseband"]) {
                boot += volume.used
            } else {
                others += volume.used
            }
        }
        return [
            ("macOS", system),
            ("Arranque", boot),
            ("Swap", swap),
            ("Otros volúmenes", others),
        ].filter { $0.size > 0 }
    }

    /// El volumen escaneado, o aquel del que es snapshot (disk3s1s1 → disk3s1).
    private func isScanned(_ volume: Volume) -> Bool {
        scannedDevice == volume.device || scannedDevice.hasPrefix(volume.device + "s")
    }

    private static func plist(_ arguments: String...) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
