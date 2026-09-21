import SwiftUI

@main
struct MiniOBSApp: App {
    @StateObject private var engine = Engine()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("MiniOBS") {
            ContentView()
                .environmentObject(engine)
        }
        .windowResizability(.contentSize)
        Settings {
            PreferencesView()
                .environmentObject(engine)
        }
        .commands {
            CommandMenu("Escena") {
                ForEach(SceneKind.allCases) { scene in
                    Button(scene.title) { engine.scene = scene }
                        .keyboardShortcut(KeyEquivalent(scene.shortcut.first!), modifiers: .command)
                }
            }
            CommandMenu("Grabación") {
                Button(engine.isRecording ? "Parar" : "Grabar") { engine.toggleRecording() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Abrir la carpeta de grabaciones") {
                    NSWorkspace.shared.open(engine.outputFolder)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Si se sale grabando, primero se cierra el MP4; si no, queda corrupto.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine = Engine.current, engine.isRecording else { return .terminateNow }
        Task { @MainActor in
            await engine.stopRecordingAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lanzada desde `open` o desde el Stream Deck: que salga delante.
        NSApp.activate(ignoringOtherApps: true)
    }
}
