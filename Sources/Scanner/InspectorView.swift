import AppKit
import ScannerCore
import SwiftUI
import UniformTypeIdentifiers

/// Panel derecho: el contenido de la carpeta enfocada o sus archivos más grandes,
/// con tamaños exactos. Llega a lo que en el gráfico es demasiado fino.
struct InspectorView: View {
    @Environment(ScanSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("inspectorTab") private var tab = Tab.contents

    enum Tab: String {
        case contents
        case largest
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mostrar", selection: $tab) {
                Text("Contenido").tag(Tab.contents)
                Text("Más grandes").tag(Tab.largest)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let focus = session.focus {
                let layout = session.cachedLayout(for: focus)
                List {
                    if session.colorByType, let sizes = focus.categorySizes {
                        Section("Por tipo") {
                            CategoryRows(sizes: sizes)
                        }
                    }
                    // La pestaña ya dice qué es; el título solo hace falta para separar de "Por tipo".
                    Section {
                        switch tab {
                        case .contents: contents(of: focus, layout: layout)
                        case .largest: largest(in: focus, layout: layout)
                        }
                    } header: {
                        if session.colorByType {
                            Text(tab == .contents ? "Contenido" : "Archivos más grandes")
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else {
                Spacer()
            }
        }
    }

    // MARK: - Contenido

    private static let maxRows = 100

    @ViewBuilder
    private func contents(of focus: FileNode, layout: SunburstLayout?) -> some View {
        let arcs = Self.firstRingArcs(layout)
        // Lo que no ocupa nada no aporta (carpetas vacías, sin acceso).
        let children = focus.children.filter { $0.size > 0 }
        ForEach(children.prefix(Self.maxRows)) { child in
            let arc = arcs[ObjectIdentifier(child)]
            row(for: child, arc: arc, layout: layout, detail: session.note(for: child), total: focus.size)
            if child.kind == .other {
                // El desglose de "Sistema y otros".
                ForEach(child.children) { part in
                    row(for: part, arc: layout?.arc(for: part), layout: layout,
                        detail: session.note(for: part), total: focus.size, indented: true)
                }
            }
        }
        if children.count > Self.maxRows {
            Text("y \((children.count - Self.maxRows).formatted()) elementos más")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Más grandes

    @ViewBuilder
    private func largest(in focus: FileNode, layout: SunburstLayout?) -> some View {
        let files = session.largestFiles(in: focus)
        if files.isEmpty {
            Text("No hay archivos.")
                .foregroundStyle(.secondary)
        }
        ForEach(files) { file in
            // Si el archivo no se ve en el gráfico, se resalta la carpeta visible que lo contiene.
            row(for: file, arc: layout.flatMap { Self.visibleArc(for: file, in: $0) }, layout: layout,
                detail: Self.relativePath(of: file.parent, in: focus), total: focus.size)
        }
    }

    private static func visibleArc(for node: FileNode, in layout: SunburstLayout) -> SunburstArc? {
        var current: FileNode? = node
        while let candidate = current, candidate !== layout.focus {
            if let arc = layout.arc(for: candidate) { return arc }
            current = candidate.parent
        }
        return nil
    }

    private static func relativePath(of folder: FileNode?, in focus: FileNode) -> String? {
        guard let folder else { return nil }
        if folder === focus { return nil }
        let base = focus.displayPath
        let path = folder.displayPath
        guard path.hasPrefix(base) else { return path }
        return String(path.dropFirst(base.count).drop { $0 == "/" })
    }

    // MARK: - Filas

    private static func firstRingArcs(_ layout: SunburstLayout?) -> [ObjectIdentifier: SunburstArc] {
        var arcs: [ObjectIdentifier: SunburstArc] = [:]
        for arc in layout?.rings.first ?? [] {
            if let node = arc.node { arcs[ObjectIdentifier(node)] = arc }
        }
        return arcs
    }

    private func row(for node: FileNode, arc: SunburstArc?, layout: SunburstLayout?, detail: String?,
                     total: Int64, indented: Bool = false) -> some View {
        let dark = colorScheme == .dark
        let color: Color = if let arc, let layout, arc.node === node {
            Palette.color(for: arc, in: layout, byType: session.colorByType, dark: dark)
        } else {
            Palette.color(for: node, position: 0, depth: 0, byType: session.colorByType, dark: dark)
                .opacity(session.colorByType || node.isSynthetic ? 1 : 0)
        }
        return ItemRow(node: node, color: color, detail: detail, share: Format.percent(node.size, of: total))
            .padding(.leading, indented ? 18 : 0)
            .onHover { inside in
                guard let arc else { return }
                if inside { session.setHover(.arc(arc)) } else { session.clearHover(ifArc: arc) }
            }
            .onTapGesture {
                if node.isDirectory {
                    session.zoom(to: node)
                } else if let parent = node.parent, parent !== session.focus {
                    session.zoom(to: parent)
                }
            }
            .contextMenu {
                if !node.isSynthetic { NodeMenu(node: node) }
            }
    }
}

private struct ItemRow: View {
    let node: FileNode
    let color: Color
    let detail: String?
    let share: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            if node.isSynthetic {
                Image(systemName: node.kind == .free ? "circle.dashed" : "internaldrive")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            } else {
                Image(nsImage: Icons.icon(for: node))
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(node.isSynthetic ? .tail : .head)
                }
            }
            Spacer(minLength: 6)
            Text(Format.bytes(node.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .help([node.name, Format.bytes(node.size), share, detail].compactMap { $0 }.joined(separator: " · "))
    }
}

/// Totales por tipo de la carpeta enfocada; al pasar el mouse se resalta en el gráfico.
struct CategoryRows: View {
    let sizes: [Int64]
    var compact = false
    @Environment(ScanSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let total = max(sizes.reduce(0, +), 1)
        let categories = FileCategory.allCases
            .filter { sizes[Int($0.rawValue)] > 0 }
            .sorted { sizes[Int($0.rawValue)] > sizes[Int($1.rawValue)] }
        ForEach(categories, id: \.self) { category in
            let size = sizes[Int(category.rawValue)]
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Palette.color(for: category, dark: colorScheme == .dark))
                    .frame(width: 10, height: 10)
                Text(category.name)
                    .lineLimit(1)
                if !compact {
                    Spacer(minLength: 6)
                    Text(Format.bytes(size))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .help("\(category.name): \(Format.bytes(size)) · \(Format.percent(size, of: total))")
            .onHover { inside in
                if inside {
                    session.highlightedCategory = category
                } else if session.highlightedCategory == category {
                    session.highlightedCategory = nil
                }
            }
        }
    }
}

/// Íconos de Finder sin leer el disco: por tipo de archivo, salvo las apps.
@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for node: FileNode) -> NSImage {
        let ext = (node.name as NSString).pathExtension.lowercased()
        if node.isDirectory && ext == "app" {
            return cached("app:" + node.path) { NSWorkspace.shared.icon(forFile: node.path) }
        }
        if node.isDirectory {
            return cached("folder") { NSWorkspace.shared.icon(for: .folder) }
        }
        return cached("ext:" + ext) {
            NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
    }

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let image = cache[key] { return image }
        if cache.count > 500 { cache.removeAll() }
        let image = make()
        cache[key] = image
        return image
    }
}
