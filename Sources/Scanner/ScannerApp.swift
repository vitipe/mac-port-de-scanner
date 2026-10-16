import AppKit
import SwiftUI

@main
struct ScannerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // La ventana la crea AppDelegate: una escena `Window` de SwiftUI no se abre
        // cuando la app arranca para abrir una carpeta (Finder, `open -a`).
        Settings { EmptyView() }
            .commands {
                ScannerCommands(session: delegate.session)
                CommandGroup(replacing: .appSettings) {}
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session: ScanSession
    private(set) var window: NSWindow?
    private var didLaunch = false
    private var pendingFolder: URL?

    override init() {
        session = ScanSession()
        super.init()
    }

    /// Carpetas abiertas con “Abrir con”, arrastradas al Dock o con `open -a Scanner`.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if didLaunch {
            session.open(url)
            NSApp.activate()
        } else {
            pendingFolder = url
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didLaunch = true
        NSApp.setActivationPolicy(.regular)
        showMainWindow()
        NSApp.activate()
        session.start(initialFolder: pendingFolder ?? Self.folderArgument())
        #if DEBUG
        scheduleDebugSnapshot()
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    private func showMainWindow() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: ContentView()
                    .environment(session)
                    .frame(minWidth: 680, minHeight: 500)
            )
            hosting.sceneBridgingOptions = .all
            let window = NSWindow(contentViewController: hosting)
            window.styleMask.insert(.fullSizeContentView)
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1000, height: 740))
            window.center()
            window.setFrameAutosaveName("MainWindow")
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Una carpeta pasada por línea de comandos, como en el original.
    private static func folderArgument() -> URL? {
        for argument in CommandLine.arguments.dropFirst() where !argument.hasPrefix("-") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: argument, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: argument, isDirectory: true)
            }
        }
        return nil
    }
}

struct ScannerCommands: Commands {
    let session: ScanSession

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Abrir carpeta…") { session.chooseFolder() }
                .keyboardShortcut("o")
        }
        CommandMenu("Ir") {
            Button("Atrás") { session.goBack() }
                .keyboardShortcut("[")
                .disabled(!session.canGoBack)
            Button("Carpeta superior") { session.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(!session.canGoUp)
            Divider()
            Button("Re-escanear carpeta") { session.rescanFocus() }
                .keyboardShortcut("r")
                .disabled(session.source == nil || session.scan != nil)
            Button("Detener escaneo") { session.cancelScan() }
                .keyboardShortcut(".")
                .disabled(session.scan == nil)
            Divider()
            Button("Acceso total al disco…") { ScanSession.openFullDiskAccessSettings() }
        }
    }
}
