import AppKit
import ScannerCore
import SwiftUI

struct SidebarView: View {
    @Environment(ScanSession.self) private var session

    var body: some View {
        // El gesto de tap cubre el clic sobre lo ya elegido, que lo re-escanea.
        List(selection: Binding(get: { session.source }, set: { if let source = $0 { session.activate(source) } })) {
            Section("Discos") {
                ForEach(session.volumes) { volume in
                    VolumeRow(volume: volume)
                        .tag(Source.volume(volume.url))
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { session.activate(.volume(volume.url)) })
                        .contextMenu {
                            Button("Re-escanear") { session.activate(.volume(volume.url)) }
                            Button("Mostrar en Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([volume.url])
                            }
                        }
                }
            }
            if !session.recentFolders.isEmpty {
                Section("Carpetas") {
                    ForEach(session.recentFolders, id: \.self) { url in
                        FolderRow(url: url)
                            .tag(Source.folder(url))
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture().onEnded { session.activate(.folder(url)) })
                            .contextMenu {
                                Button("Re-escanear") { session.activate(.folder(url)) }
                                Button("Mostrar en Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                                Divider()
                                Button("Quitar de la lista") { session.removeRecent(url) }
                            }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TrashRow()
                Button {
                    session.chooseFolder()
                } label: {
                    Label("Elegir carpeta…", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }
}

/// La Papelera, como el "Recycle Bin" del original: cuánto ocupa, verla en el
/// gráfico con un clic y vaciarla.
private struct TrashRow: View {
    @Environment(ScanSession.self) private var session

    var body: some View {
        let trash = session.trash
        HStack(spacing: 8) {
            Image(nsImage: NSImage(named: trash.isEmpty ? NSImage.trashEmptyName : NSImage.trashFullName) ?? NSImage())
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Papelera")
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            if trash.isEmptying {
                ProgressView()
                    .controlSize(.small)
            } else if !trash.isEmpty {
                Button("Vaciar") { session.confirmingEmptyTrash = true }
                    .controlSize(.small)
                    .help("Vaciar la Papelera")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(session.source == .trash ? Color.accentColor.opacity(0.2) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { session.activate(.trash) }
        .contextMenu {
            Button("Mostrar en Finder") { NSWorkspace.shared.open(ScanSession.userTrash) }
            Button("Vaciar Papelera…") { session.confirmingEmptyTrash = true }
                .disabled(trash.isEmpty || trash.isEmptying)
        }
        .help("Ver en el gráfico qué hay en la Papelera")
    }

    private var caption: String {
        let trash = session.trash
        if trash.isEmptying { return "Vaciando…" }
        guard let size = trash.size else { return "Sin acceso" }
        return trash.isEmpty ? "Vacía" : Format.bytes(size)
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: volume.url.path))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name)
                    .lineLimit(1)
                ProgressView(value: Double(volume.usedCapacity), total: Double(max(volume.totalCapacity, 1)))
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                Text("\(Format.bytes(volume.availableCapacity)) libres de \(Format.bytes(volume.totalCapacity))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FolderRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 20, height: 20)
            Text(url.lastPathComponent)
                .lineLimit(1)
                .help(url.path)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
