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
                .inspector(isPresented: $session.showsInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 250, ideal: 300, max: 420)
                }
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
        .confirmationDialog("¿Vaciar la Papelera?", isPresented: $session.confirmingEmptyTrash, titleVisibility: .visible) {
            Button("Vaciar Papelera", role: .destructive) { session.emptyTrash() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            if let size = session.trash.size {
                Text("Se van a borrar \(Format.bytes(size)) para siempre. No se puede deshacer.")
            } else {
                Text("Se va a borrar todo lo que tiene para siempre. No se puede deshacer.")
            }
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
        .overlay(alignment: .bottomLeading) {
            // Sin el panel, la leyenda del color por tipo va sobre el gráfico.
            if session.colorByType, !session.showsInspector, !isFullScan,
               let sizes = session.focus?.categorySizes {
                VStack(alignment: .leading, spacing: 4) {
                    CategoryRows(sizes: sizes, compact: true)
                }
                .font(.caption)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(12)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var session = session
        ToolbarItemGroup(placement: .navigation) {
            Button("Atrás", systemImage: "chevron.left") { session.goBack() }
                .disabled(!session.canGoBack)
                .help("Atrás (⌘[)")
            Button("Carpeta superior", systemImage: "arrow.up") { session.goUp() }
                .disabled(!session.canGoUp)
                .help("Carpeta superior (⌘↑)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if session.scan != nil {
                Button("Detener", systemImage: "stop.fill") { session.cancelScan() }
                    .help("Detener el escaneo (⌘.)")
            } else {
                Button("Re-escanear carpeta", systemImage: "arrow.clockwise") { session.rescanFocus() }
                    .disabled(session.source == nil)
                    .help("Re-escanear carpeta (⌘R)")
            }
            Toggle(isOn: $session.colorByType) {
                Label("Colorear por tipo", systemImage: "paintpalette")
            }
            .help("Colorear por tipo de archivo (⌘T)")
            Button("Detalles", systemImage: "sidebar.trailing") { session.showsInspector.toggle() }
                .help("Mostrar u ocultar los detalles (⌥⌘I)")
        }
    }
}

private struct ScanningCard: View {
    let scan: ScanStatus

    var body: some View {
        VStack(spacing: 10) {
            if let fraction {
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
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

    /// Avance según lo que el sistema dice que hay; nunca llega a 100 % antes de terminar.
    private var fraction: Double? {
        guard let expected = scan.expectedBytes, expected > 0 else { return nil }
        return min(0.99, Double(scan.bytes) / Double(expected))
    }
}
