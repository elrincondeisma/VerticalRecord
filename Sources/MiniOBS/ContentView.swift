import AVFoundation
import ScreenCaptureKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        HStack(spacing: 0) {
            PreviewView(host: engine.preview)
                .aspectRatio(engine.canvas.aspect, contentMode: .fit)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            sidebar
                .frame(width: 320)
        }
        .frame(minWidth: 760, minHeight: 640)
        .onAppear { engine.start() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Escena") {
                Picker("Escena", selection: $engine.scene) {
                    ForEach(SceneKind.allCases) { scene in
                        Text("\(scene.title)  ⌘\(scene.shortcut)").tag(scene)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(engine.scene == .split
                     ? "Arriba 2/3 la ventana elegida, abajo 1/3 la cámara."
                     : "La cámara a todo el lienzo (recorta los laterales).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            section("Ventana (escena dividida)") {
                HStack {
                    if let demo = engine.demo {
                        Picker("Ventana", selection: .constant(0)) {
                            ForEach(Array(demo.windowNames.enumerated()), id: \.offset) { i, name in
                                Text(name).tag(i)
                            }
                        }
                        .labelsHidden()
                    } else {
                        Picker("Ventana", selection: $engine.windowID) {
                            Text("Ninguna").tag(CGWindowID(0))
                            ForEach(engine.windows, id: \.windowID) { w in
                                Text(engine.windowLabel(w)).tag(w.windowID)
                            }
                        }
                        .labelsHidden()
                    }
                    Button {
                        Task { await engine.refreshDevices() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Volver a buscar ventanas y dispositivos")
                }
                HStack {
                    Button("Ajustar la ventana al hueco") { engine.fitWindowToSlot() }
                        .disabled(engine.selectedWindow == nil && engine.demo == nil)
                    if engine.canUndoFit {
                        Button("Deshacer") { engine.undoFitWindow() }
                    }
                }
                Text("Le da a la ventana la proporción del hueco (2160×2560) para que entre entera y sin franjas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            section("Cámara") {
                if engine.demo != nil {
                    Picker("Cámara", selection: .constant(0)) { Text("OBSBOT Tiny 2 Lite").tag(0) }.labelsHidden()
                } else {
                    Picker("Cámara", selection: $engine.cameraID) {
                        ForEach(engine.cameras, id: \.uniqueID) { d in
                            Text(d.localizedName).tag(d.uniqueID)
                        }
                    }
                    .labelsHidden()
                }
                HStack {
                    Text("Encuadre")
                    Slider(value: $engine.cameraOffset, in: -1...1)
                    Button("Centrar") { engine.cameraOffset = 0 }
                        .font(.caption)
                        .disabled(engine.cameraOffset == 0)
                }
                .font(.callout)
                Text("Desplaza el recorte de la cámara a izquierda o derecha.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            section("Micrófono") {
                if engine.demo != nil {
                    Picker("Micrófono", selection: .constant(0)) { Text("Maonocaster E2").tag(0) }.labelsHidden()
                } else {
                    Picker("Micrófono", selection: $engine.microphoneID) {
                        ForEach(engine.microphones, id: \.uniqueID) { d in
                            Text(d.localizedName).tag(d.uniqueID)
                        }
                    }
                    .labelsHidden()
                }
            }

            section("Grabación") {
                Button(action: engine.toggleRecording) {
                    HStack {
                        Image(systemName: engine.isRecording ? "stop.fill" : "record.circle")
                        Text(engine.isRecording ? "Parar  \(clock(engine.recordingSeconds))" : "Grabar  ⌘R")
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .tint(engine.isRecording ? .gray : .red)
                .buttonStyle(.borderedProminent)

                HStack {
                    Text("\(engine.canvas.label) · \(Canvas.fps) fps · \(engine.codec.title)" + (engine.codec.usesBitrate ? " · \(engine.bitrateMbps) Mbps" : ""))
                    Spacer()
                    SettingsLink { Text("Preferencias…") }
                        .font(.caption)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(engine.outputFolder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let last = engine.lastRecording {
                    Button("Mostrar la última en el Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([last])
                    }
                    .font(.caption)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                if let problem = engine.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Text(engine.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Mando: http://127.0.0.1:\(ControlServer.defaultPort)/status")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
