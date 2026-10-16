import Foundation

/// Tipo de contenido, para colorear por tipo y sumar cuánto ocupa cada uno.
public enum FileCategory: UInt8, CaseIterable, Sendable {
    case video
    case images
    case audio
    case documents
    case archives
    case apps
    case developer
    case caches
    case other

    public var name: String {
        switch self {
        case .video: "Video"
        case .images: "Imágenes"
        case .audio: "Audio"
        case .documents: "Documentos"
        case .archives: "Comprimidos y discos"
        case .apps: "Apps"
        case .developer: "Desarrollo"
        case .caches: "Cachés y registros"
        case .other: "Otros"
        }
    }

    /// Categoría de un archivo según su extensión.
    public static func forFile(named name: String) -> FileCategory {
        guard let ext = pathExtension(of: name) else { return .other }
        return fileExtensions[ext] ?? .other
    }

    /// Categoría que hereda todo lo que hay dentro de una carpeta, si la carpeta la
    /// define por sí sola: el contenido de un `.app` son apps, el de `node_modules`
    /// es desarrollo, etc.
    public static func forDirectory(named name: String) -> FileCategory? {
        if let category = directoryNames[name] { return category }
        guard let ext = pathExtension(of: name) else { return nil }
        return directoryExtensions[ext]
    }

    private static func pathExtension(of name: String) -> String? {
        let utf8 = name.utf8
        guard let dot = utf8.lastIndex(of: UInt8(ascii: ".")), dot != utf8.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty, ext.utf8.count <= 12 else { return nil }
        return ext.lowercased()
    }

    private static let fileExtensions: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        func add(_ category: FileCategory, _ extensions: String) {
            for ext in extensions.split(separator: " ") { map[String(ext)] = category }
        }
        add(.video, "mp4 m4v mov mkv avi wmv flv webm mpg mpeg m2ts mts 3gp vob braw r3d")
        add(.images, "jpg jpeg png heic heif gif tif tiff bmp webp raw cr2 cr3 nef arw dng raf orf rw2 psd psb ai svg xcf exr")
        add(.audio, "mp3 m4a m4b m4p aac wav aif aiff flac alac ogg oga opus wma caf mid midi")
        add(.documents, "pdf doc docx xls xlsx ppt pptx pages numbers key txt rtf md odt ods odp csv epub tex")
        add(.archives, "zip rar 7z tar gz tgz bz2 xz zst lz4 lzma dmg iso img pkg mpkg sparseimage xip cab")
        add(.developer, """
            swift m mm h hpp c cc cpp js mjs cjs ts tsx jsx py pyc rb go rs java class jar kt php \
            json yml yaml toml xml html css scss sql sh o a so dylib wasm map lock ipa
            """)
        add(.caches, "log tmp temp cache")
        return map
    }()

    private static let directoryExtensions: [String: FileCategory] = [
        "app": .apps, "framework": .apps, "bundle": .apps, "appex": .apps, "plugin": .apps,
        "kext": .apps, "xpc": .apps, "prefpane": .apps, "qlgenerator": .apps, "saver": .apps,
        "photoslibrary": .images, "photolibrary": .images,
        "fcpbundle": .video, "imovielibrary": .video,
        "logicx": .audio, "band": .audio,
        "sparsebundle": .archives,
        "xcarchive": .developer, "dsym": .developer, "xcodeproj": .developer, "xcworkspace": .developer,
    ]

    private static let directoryNames: [String: FileCategory] = [
        "node_modules": .developer, ".git": .developer, "DerivedData": .developer, ".build": .developer,
        "Pods": .developer, ".gradle": .developer, ".cargo": .developer, ".rustup": .developer,
        ".npm": .developer, ".pnpm-store": .developer, "site-packages": .developer, ".venv": .developer,
        "venv": .developer, "CoreSimulator": .developer,
        "Caches": .caches, "Cache": .caches, "cache": .caches, ".cache": .caches, "Logs": .caches,
    ]
}
