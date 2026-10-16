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
            Button {
                session.chooseFolder()
            } label: {
                Label("Elegir carpeta…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
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
