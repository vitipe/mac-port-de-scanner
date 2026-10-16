import ScannerCore
import SwiftUI

/// Barra inferior: progreso del escaneo, o detalles de lo que está bajo el cursor.
struct InfoBar: View {
    @Environment(ScanSession.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            if let scan = session.scan {
                ProgressView().controlSize(.small)
                Text(scan.isFull ? "Escaneando…" : "Re-escaneando…")
                Text("\(Format.files(scan.files)) · \(Format.bytes(scan.bytes))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(scan.currentPath)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let arc = session.hover?.arc, let focus = session.focus {
                details(for: arc, in: focus)
            } else if let focus = session.focus {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(focus.name).fontWeight(.medium)
                Text("\(Format.bytes(focus.size)) · \(Format.files(focus.fileCount))")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if session.scan == nil && session.inaccessibleCount > 0 {
                Button {
                    ScanSession.openFullDiskAccessSettings()
                } label: {
                    Label(
                        session.inaccessibleCount == 1
                            ? "1 carpeta sin acceso"
                            : "\(session.inaccessibleCount.formatted()) carpetas sin acceso",
                        systemImage: "lock"
                    )
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Algunas carpetas no se pudieron leer. Dale a Scanner “Acceso total al disco” en Ajustes del Sistema para incluirlas.")
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func details(for arc: SunburstArc, in focus: FileNode) -> some View {
        Circle()
            .fill(Palette.color(for: arc, contentSpan: session.contentSpan, dark: colorScheme == .dark))
            .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
            .frame(width: 10, height: 10)
        switch arc.content {
        case .node(let node):
            Text(node.name).fontWeight(.medium)
            Text(summary(size: node.size, of: focus, files: node.isDirectory ? node.fileCount : nil))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if !node.isSynthetic {
                Text(node.displayPath)
                    .foregroundStyle(.tertiary)
                    .truncationMode(.middle)
            }
            if node.isInaccessible {
                Image(systemName: "lock").foregroundStyle(.secondary).help("Sin acceso")
            }
        case .smaller(let parent, let count, let size):
            Text("\(count.formatted()) elementos más chicos").fontWeight(.medium)
            Text(summary(size: size, of: focus, files: nil))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(parent.displayPath)
                .foregroundStyle(.tertiary)
                .truncationMode(.middle)
        }
    }

    private func summary(size: Int64, of focus: FileNode, files: Int?) -> String {
        var parts = [Format.bytes(size), Format.percent(size, of: focus.size)]
        if let files { parts.append(Format.files(files)) }
        return parts.joined(separator: " · ")
    }
}
