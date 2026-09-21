import SwiftUI

/// Preferencias (⌘,): calidad, formato y carpeta de salida. Calidad y formato
/// se bloquean mientras se graba: cambiarlos a mitad rompería el fichero.
struct PreferencesView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        Form {
            Section("Grabación") {
                Picker("Calidad", selection: $engine.quality) {
                    ForEach(Quality.allCases) { q in Text(q.title).tag(q) }
                }
                .disabled(engine.isRecording)
                Text("La cámara se captura siempre a su máxima resolución; la calidad decide el tamaño del vídeo final.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Formato", selection: $engine.codec) {
                    ForEach(Codec.allCases) { c in Text(c.title).tag(c) }
                }
                .disabled(engine.isRecording)
                Text(engine.codec.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if engine.codec.usesBitrate {
                    HStack {
                        Stepper("Bitrate: \(engine.bitrateMbps) Mbps", value: $engine.bitrateMbps, in: 4...200, step: 2)
                            .disabled(engine.isRecording)
                        Spacer()
                        Button("Recomendado (\(recommendedBitrate) Mbps)") { engine.bitrateMbps = recommendedBitrate }
                            .disabled(engine.isRecording || engine.bitrateMbps == recommendedBitrate)
                    }
                }
            }

            Section("Carpeta de salida") {
                HStack {
                    Text(engine.outputFolder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Elegir…") { chooseFolder() }
                    Button {
                        NSWorkspace.shared.open(engine.outputFolder)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Abrir en el Finder")
                }
                if engine.outputFolder != Engine.defaultOutputFolder {
                    Button("Volver a ~/Movies/MiniOBS") { engine.outputFolder = Engine.defaultOutputFolder }
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var recommendedBitrate: Int {
        // H.264 necesita más bits que HEVC para verse igual.
        engine.codec == .h264 ? engine.quality.defaultBitrateMbps * 2 : engine.quality.defaultBitrateMbps
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = engine.outputFolder
        panel.prompt = "Usar esta carpeta"
        if panel.runModal() == .OK, let url = panel.url {
            engine.outputFolder = url
        }
    }
}
