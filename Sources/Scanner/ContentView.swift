import ScannerCore
import SwiftUI

struct ContentView: View {
    @Environment(ScanSession.self) private var session

    var body: some View {
        @Bindable var session = session
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            chartArea
                .safeAreaInset(edge: .bottom, spacing: 0) { InfoBar() }
                .navigationTitle(session.focus?.name ?? "Scanner")
                .navigationSubtitle(session.focus.map { $0.displayPath == "/" ? "" : $0.displayPath } ?? "")
                .toolbar { toolbar }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            session.open(url)
            return true
        }
        .confirmationDialog(
            session.pendingTrash.map { "¿Mover “\($0.name)” a la Papelera?" } ?? "",
            isPresented: Binding(
                get: { session.pendingTrash != nil },
                set: { if !$0 { session.pendingTrash = nil } }
            ),
            titleVisibility: .visible,
            presenting: session.pendingTrash
        ) { node in
            Button("Mover a la Papelera", role: .destructive) { session.trash(node) }
            Button("Cancelar", role: .cancel) {}
        } message: { node in
            Text("\(Format.bytes(node.size)) · \(node.displayPath)")
        }
        .alert(
            "Scanner",
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            ),
            actions: { Button("OK") {} },
            message: { Text(session.errorMessage ?? "") }
        )
    }

    private var isFullScan: Bool { session.scan?.isFull == true }

    private var chartArea: some View {
        ZStack {
            if let focus = session.focus {
                ChartView(focus: focus)
                    .id(ObjectIdentifier(focus))
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94)),
                        removal: .opacity
                    ))
                    .opacity(isFullScan ? 0.25 : 1)
                    .allowsHitTesting(!isFullScan)
            } else if session.scan == nil {
                ContentUnavailableView {
                    Label("Elegí un disco o una carpeta", systemImage: "circle.dotted.circle")
                } description: {
                    Text("También podés arrastrar una carpeta a esta ventana.")
                }
            }
            if isFullScan, let scan = session.scan {
                ScanningCard(scan: scan)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Atrás", systemImage: "chevron.left") { session.goBack() }
                .disabled(!session.canGoBack)
                .help("Atrás (⌘[)")
            Button("Carpeta superior", systemImage: "arrow.up") { session.goUp() }
                .disabled(!session.canGoUp)
                .help("Carpeta superior (⌘↑)")
        }
        ToolbarItem(placement: .primaryAction) {
            if session.scan != nil {
                Button("Detener", systemImage: "stop.fill") { session.cancelScan() }
                    .help("Detener el escaneo (⌘.)")
            } else {
                Button("Re-escanear carpeta", systemImage: "arrow.clockwise") { session.rescanFocus() }
                    .disabled(session.source == nil)
                    .help("Re-escanear carpeta (⌘R)")
            }
        }
    }
}

private struct ScanningCard: View {
    let scan: ScanStatus

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text("Escaneando…")
                .font(.headline)
            Text("\(Format.files(scan.files)) · \(Format.bytes(scan.bytes))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(scan.currentPath)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360)
        }
        .padding(24)
        .frame(minWidth: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
