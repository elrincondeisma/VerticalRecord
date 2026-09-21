import AVFoundation
import Combine
import CoreMedia
import ScreenCaptureKit
import SwiftUI

/// El motor: captura, compone a 30 fps, enseña la vista previa y graba.
/// Todo el estado que ve la interfaz vive aquí, en el hilo principal; la
/// composición corre en su propia cola y solo lee copias.
@MainActor
final class Engine: ObservableObject {
    @Published var scene: SceneKind = .split { didSet { sync() ; save() } }
    @Published private(set) var isRecording = false
    @Published private(set) var recordingSeconds = 0
    @Published private(set) var lastRecording: URL?
    @Published private(set) var status = "Arrancando…"
    @Published private(set) var problem: String?

    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var microphones: [AVCaptureDevice] = []
    @Published private(set) var windows: [SCWindow] = []

    @Published var cameraID: String = "" { didSet { if oldValue != cameraID { restartCapture(); save() } } }
    @Published var microphoneID: String = "" { didSet { if oldValue != microphoneID { restartCapture(); save() } } }
    @Published var windowID: CGWindowID = 0 { didSet { if oldValue != windowID { restartScreen(); save() } } }
    @Published var bitrateMbps: Int = 50 { didSet { save() } }
    @Published var quality: Quality = .uhd { didSet { if oldValue != quality { rebuildCompositor(); save() } } }
    @Published var codec: Codec = .hevc { didSet { save() } }
    @Published var outputFolder: URL = Engine.defaultOutputFolder { didSet { save() } }
    /// Encuadre horizontal de la cámara: -1 izquierda, 0 centro, 1 derecha.
    @Published var cameraOffset: Double = 0 { didSet { sync(); save() } }

    let preview = PreviewLayerHost()
    static let defaultOutputFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/MiniOBS", isDirectory: true)

    var canvas: Canvas { quality.canvas }

    private let camera = CameraCapture()
    private let screen = ScreenCapture()
    private var control: ControlServer?

    private let renderQueue = DispatchQueue(label: "miniobs.render", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let shared = SharedState()
    private var secondsTimer: Timer?
    private var started = false

    // MARK: - Arranque

    /// La instancia viva, para que el delegado de la app cierre la grabación
    /// antes de salir.
    static private(set) weak var current: Engine?

    /// Modo demo (`MINIOBS_DEMO=/carpeta` con `camera.png` y `window.png`): en
    /// vez de capturar, compone esas imágenes. Sirve para hacer capturas de la
    /// app sin enseñar a nadie ni ninguna pantalla.
    let demo: Demo?

    struct Demo {
        let camera: CVPixelBuffer
        let window: ScreenFrame
        let windowNames = ["Warp — miniobs", "Xcode — MiniOBS.xcodeproj", "Arc — Documentación"]
    }

    init() {
        demo = ProcessInfo.processInfo.environment["MINIOBS_DEMO"].flatMap(Engine.loadDemo)
        Engine.current = self
    }

    private static func loadDemo(_ folder: String) -> Demo? {
        func buffer(_ name: String) -> CVPixelBuffer? {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            guard let image = CIImage(contentsOf: url) else { return nil }
            var pb: CVPixelBuffer?
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
            guard CVPixelBufferCreate(nil, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
                  let pb else { return nil }
            CIContext().render(image, to: pb)
            return pb
        }
        guard let cam = buffer("camera.png"), let win = buffer("window.png") else { return nil }
        let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(win), height: CVPixelBufferGetHeight(win))
        return Demo(camera: cam, window: ScreenFrame(buffer: win, content: rect))
    }

    func start() {
        guard !started else { return }
        load()
        started = true

        rebuildCompositor()
        guard shared.compositor != nil else { return }

        camera.onAudio = { [shared] sample in
            shared.recorder?.appendAudio(sample)
        }
        camera.onEvent = { [weak self] message in
            Task { @MainActor in self?.status = message }
        }
        screen.onStop = { [weak self] error in
            Task { @MainActor in
                self?.status = "La ventana capturada se ha cerrado" + (error.map { ": \($0.localizedDescription)" } ?? "")
            }
        }
        screen.onResize = { [weak self] in
            Task { @MainActor in
                // Medio segundo: que el usuario termine de arrastrar el borde.
                try? await Task.sleep(for: .milliseconds(600))
                await self?.reattachWindow()
            }
        }

        startControlServer()
        startRenderLoop()

        // Al volver a MiniOBS (viniendo de abrir otra app, por ejemplo) la
        // lista de ventanas se pone al día sola.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshWindows() }
        }

        if demo != nil {
            status = "Cámara: OBSBOT Tiny 2 Lite · Micro: Maonocaster E2"
            return
        }

        Task {
            let access = await CameraCapture.requestAccess()
            if !access.camera { problem = CaptureError.notAuthorized("la cámara").localizedDescription }
            if !access.mic { problem = CaptureError.notAuthorized("el micrófono").localizedDescription }
            await refreshDevices()
            restartCapture()
            restartScreen()
        }
    }

    func refreshDevices() async {
        cameras = CameraCapture.cameras()
        microphones = CameraCapture.microphones()
        if cameraID.isEmpty || !cameras.contains(where: { $0.uniqueID == cameraID }) {
            cameraID = (cameras.first { $0.localizedName.contains("OBSBOT") } ?? cameras.first)?.uniqueID ?? ""
        }
        if microphoneID.isEmpty || !microphones.contains(where: { $0.uniqueID == microphoneID }) {
            microphoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.uniqueID ?? ""
        }
        await refreshWindows()
    }

    func refreshWindows() async {
        guard started, demo == nil else { return }
        do {
            windows = try await ScreenCapture.windows()
            if !windows.contains(where: { $0.windowID == windowID }) {
                windowID = resolveSavedWindow()?.windowID ?? 0
            }
        } catch {
            problem = "Sin permiso de grabación de pantalla: \(error.localizedDescription)"
        }
    }

    var selectedWindow: SCWindow? { windows.first { $0.windowID == windowID } }

    func windowLabel(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "?"
        let title = (w.title ?? "").trimmingCharacters(in: .whitespaces)
        let size = "\(Int(w.frame.width))×\(Int(w.frame.height))"
        return title.isEmpty ? "\(app) — \(size)" : "\(app) — \(title)"
    }

    // MARK: - Captura

    private func restartCapture() {
        guard started else { return }
        let cam = cameras.first { $0.uniqueID == cameraID }
        let mic = microphones.first { $0.uniqueID == microphoneID }
        status = "Arrancando \(cam?.localizedName ?? "sin cámara")…"
        camera.reconfigure(camera: cam, microphone: mic) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.problem = error.localizedDescription
                } else {
                    self.status = "Cámara: \(cam?.localizedName ?? "ninguna") · Micro: \(mic?.localizedName ?? "ninguno")"
                }
            }
        }
    }

    private func restartScreen() {
        guard started else { return }
        let window = selectedWindow
        Task {
            if let window {
                do {
                    try await screen.start(window: window)
                    problem = nil
                } catch {
                    problem = "No se puede capturar la ventana: \(error.localizedDescription)"
                }
            } else {
                await screen.stop()
            }
        }
    }

    /// Vuelve a arrancar la captura con el tamaño actual de la ventana.
    func reattachWindow() async {
        let id = windowID
        await refreshDevices()
        if windowID == id { restartScreen() }
    }

    /// Proporción (ancho/alto) del hueco de la ventana en la escena dividida.
    var windowSlotAspect: CGFloat {
        let slot = Layout.of(.split, in: canvas).screen!
        return slot.width / slot.height
    }

    /// Cómo estaba la ventana antes de ajustarla, para poder deshacerlo.
    @Published private(set) var frameBeforeFit: (windowID: CGWindowID, frame: CGRect)?

    var canUndoFit: Bool { frameBeforeFit?.windowID == windowID }

    /// Redimensiona la ventana capturada para que llene el hueco sin franjas ni
    /// recortes. Requiere Accesibilidad; la primera vez lo pide.
    func fitWindowToSlot() {
        guard let window = selectedWindow else { problem = CaptureError.noWindow.localizedDescription; return }
        guard WindowFitter.isTrusted else {
            WindowFitter.requestTrust()
            problem = FitError.notTrusted.localizedDescription
            return
        }
        do {
            let before = window.frame
            let size = try WindowFitter.fit(window, aspect: windowSlotAspect)
            // Solo se recuerda el primer estado: ajustar dos veces seguidas no
            // debe «deshacer» a un tamaño ya ajustado.
            if !canUndoFit { frameBeforeFit = (window.windowID, before) }
            problem = nil
            status = "Ventana ajustada a \(Int(size.width))×\(Int(size.height)) (antes \(Int(before.width))×\(Int(before.height)))"
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                await reattachWindow()
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Devuelve la ventana al tamaño y sitio que tenía antes del ajuste.
    func undoFitWindow() {
        guard let saved = frameBeforeFit, saved.windowID == windowID, let window = selectedWindow else { return }
        do {
            try WindowFitter.restore(window, to: saved.frame)
            frameBeforeFit = nil
            problem = nil
            status = "Ventana devuelta a \(Int(saved.frame.width))×\(Int(saved.frame.height))"
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                await reattachWindow()
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Un compositor nuevo para el lienzo actual. La cola de render coge el
    /// que haya en cada tic, así que se puede cambiar en caliente.
    private func rebuildCompositor() {
        do {
            shared.compositor = try Compositor(canvas: canvas)
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Composición

    private func startRenderLoop() {
        sync()
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        let interval = 1.0 / Double(Canvas.fps)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [camera, screen, shared, preview, demo] in
            guard let compositor = shared.compositor else { return }
            let (scene, offset) = shared.snapshot
            let cameraFrame = demo?.camera ?? camera.latestFrame
            let screenFrame = demo?.window ?? screen.latestFrame
            guard let frame = compositor.compose(scene: scene, camera: cameraFrame, screen: screenFrame, cameraOffset: offset) else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            preview.show(frame, at: now)
            shared.recorder?.appendVideo(frame, at: now)
        }
        timer.resume()
        self.timer = timer
    }

    /// Copia para la cola de render de lo que decide el hilo principal.
    private func sync() {
        shared.set(scene: scene, cameraOffset: cameraOffset)
    }

    // MARK: - Grabación

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard !isRecording else { return }
        do {
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let url = outputFolder.appendingPathComponent("\(formatter.string(from: Date())).\(codec.fileExtension)")
            let recorder = try Recorder(url: url, canvas: canvas, codec: codec, bitrateMbps: bitrateMbps, audioFormat: camera.audioFormat)
            shared.recorder = recorder
            isRecording = true
            recordingSeconds = 0
            problem = nil
            status = "Grabando en \(url.lastPathComponent)" + (recorder.hasAudio ? "" : " (sin audio: el micro aún no había sonado)")
            secondsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.recordingSeconds += 1 }
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    func stopRecording() {
        Task { await stopRecordingAndWait() }
    }

    /// Para y CIERRA el fichero antes de volver: es lo que hay que esperar al
    /// salir de la app, o el MP4 queda corrupto.
    func stopRecordingAndWait() async {
        guard isRecording, let recorder = shared.recorder else { return }
        shared.recorder = nil
        isRecording = false
        secondsTimer?.invalidate()
        secondsTimer = nil
        status = "Cerrando \(recorder.url.lastPathComponent)…"
        do {
            try await recorder.finish()
            lastRecording = recorder.url
            status = "Guardado \(recorder.url.lastPathComponent)"
                + (recorder.droppedFrames > 0 ? " · \(recorder.droppedFrames) fotogramas perdidos" : "")
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Mando (Stream Deck)

    private func startControlServer() {
        let server = ControlServer { [weak self] path in
            guard let self else { return ["error": "stopped"] }
            return await self.handle(path)
        }
        do {
            try server.start()
            control = server
        } catch {
            problem = "El mando HTTP no ha podido escuchar en el puerto \(ControlServer.defaultPort): \(error.localizedDescription)"
        }
    }

    private func handle(_ path: String) async -> [String: Any] {
        var extra: [String: Any] = [:]
        switch path {
        case "/", "/status": break
        case "/scene/camera": scene = .camera
        case "/scene/split": scene = .split
        case "/record/start": startRecording()
        case "/record/stop": stopRecording()
        case "/record/toggle": toggleRecording()
        case "/window/fit": fitWindowToSlot()
        case "/window/unfit": undoFitWindow()
        case "/windows":
            await refreshDevices()
            extra["windows"] = windows.map { ["id": Int($0.windowID), "app": $0.owningApplication?.applicationName ?? "", "title": $0.title ?? ""] }
        case _ where path.hasPrefix("/window/"):
            // /window/<id>  o  /window/<nombre de app>: la primera ventana de esa app.
            let key = String(path.dropFirst("/window/".count)).removingPercentEncoding ?? ""
            await refreshDevices()
            if let id = UInt32(key), windows.contains(where: { $0.windowID == id }) {
                windowID = id
            } else if let w = windows.first(where: { $0.owningApplication?.applicationName.lowercased() == key.lowercased() }) {
                windowID = w.windowID
            } else {
                extra["error"] = "not_found"
            }
        default: extra["error"] = "not_found"
        }
        var body: [String: Any] = [
            "scene": scene.rawValue,
            "recording": isRecording,
            "seconds": recordingSeconds,
            "window": selectedWindow.map(windowLabel) ?? "",
            "camera": cameras.first { $0.uniqueID == cameraID }?.localizedName ?? "",
            "last": lastRecording?.path ?? "",
            "status": status,
            "problem": problem ?? "",
            "quality": quality.rawValue,
            "codec": codec.rawValue,
            "folder": outputFolder.path,
        ]
        body.merge(extra) { $1 }
        return body
    }

    // MARK: - Preferencias

    private struct Saved: Codable {
        var scene: SceneKind?
        var cameraID: String?
        var microphoneID: String?
        var windowApp: String?
        var windowTitle: String?
        var bitrateMbps: Int?
        var cameraOffset: Double?
        var quality: Quality?
        var codec: Codec?
        var outputFolder: String?
    }

    private var savedWindowApp: String?
    private var savedWindowTitle: String?

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: "saved"),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        if let s = saved.scene { scene = s }
        cameraID = saved.cameraID ?? ""
        microphoneID = saved.microphoneID ?? ""
        savedWindowApp = saved.windowApp
        savedWindowTitle = saved.windowTitle
        if let b = saved.bitrateMbps { bitrateMbps = b }
        if demo == nil, let o = saved.cameraOffset { cameraOffset = o }
        if let q = saved.quality { quality = q }
        if let c = saved.codec { codec = c }
        if let f = saved.outputFolder { outputFolder = URL(fileURLWithPath: f, isDirectory: true) }
    }

    private func save() {
        guard started else { return }
        let w = selectedWindow
        let saved = Saved(
            scene: scene,
            cameraID: cameraID,
            microphoneID: microphoneID,
            windowApp: w?.owningApplication?.bundleIdentifier ?? savedWindowApp,
            windowTitle: w?.title ?? savedWindowTitle,
            bitrateMbps: bitrateMbps,
            cameraOffset: cameraOffset,
            quality: quality,
            codec: codec,
            outputFolder: outputFolder.path
        )
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: "saved")
        }
    }

    /// La ventana guardada, si sigue abierta: misma app y mismo título; si el
    /// título cambió (Warp lo cambia con cada pestaña), cualquier ventana de
    /// esa app.
    private func resolveSavedWindow() -> SCWindow? {
        guard let app = savedWindowApp else { return nil }
        let ofApp = windows.filter { $0.owningApplication?.bundleIdentifier == app }
        return ofApp.first { $0.title == savedWindowTitle } ?? ofApp.first
    }
}

/// Lo que comparten el hilo principal y la cola de render.
private final class SharedState: @unchecked Sendable {
    private let lock = NSLock()
    private var _scene: SceneKind = .split
    private var _cameraOffset: Double = 0
    private var _recorder: Recorder?
    private var _compositor: Compositor?

    var compositor: Compositor? {
        get { lock.lock(); defer { lock.unlock() }; return _compositor }
        set { lock.lock(); _compositor = newValue; lock.unlock() }
    }

    var snapshot: (SceneKind, Double) {
        lock.lock(); defer { lock.unlock() }
        return (_scene, _cameraOffset)
    }

    func set(scene: SceneKind, cameraOffset: Double) {
        lock.lock()
        _scene = scene
        _cameraOffset = cameraOffset
        lock.unlock()
    }

    var recorder: Recorder? {
        get { lock.lock(); defer { lock.unlock() }; return _recorder }
        set { lock.lock(); _recorder = newValue; lock.unlock() }
    }
}
