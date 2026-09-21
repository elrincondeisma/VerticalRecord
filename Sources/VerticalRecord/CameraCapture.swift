import AVFoundation
import CoreMedia

/// Cámara y micrófono en una sola AVCaptureSession: así los dos van con el
/// mismo reloj (el del host) y el grabador puede mezclar sus tiempos sin más.
final class CameraCapture: NSObject {
    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "verticalrecord.camera.video")
    private let audioQueue = DispatchQueue(label: "verticalrecord.camera.audio")
    /// Arrancar y parar la sesión bloquea (la OBSBOT tarda ~1 s en despertar):
    /// nunca desde el hilo principal.
    private let sessionQueue = DispatchQueue(label: "verticalrecord.camera.session")
    private var observers: [NSObjectProtocol] = []
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let lock = NSLock()
    private var _latest: CVPixelBuffer?
    private var _audioFormat: CMFormatDescription?

    /// Se llama en la cola de audio con cada bloque del micro.
    var onAudio: ((CMSampleBuffer) -> Void)?
    /// Se llama (en la cola de sesión) cuando la sesión falla o se recupera.
    var onEvent: ((String) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.recover(after: error)
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
            self?.onEvent?("Captura interrumpida (¿otra app ha cogido la cámara?)")
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] _ in
            self?.onEvent?("Captura recuperada")
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// La sesión ha muerto (cámara desenchufada, error del driver): se intenta
    /// arrancar de nuevo pasado un segundo, en vez de dejar la vista congelada.
    private func recover(after error: Error?) {
        onEvent?("Error de captura: \(error?.localizedDescription ?? "desconocido"). Reintentando…")
        sessionQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !session.isRunning else { return }
            session.startRunning()
            onEvent?(session.isRunning ? "Captura recuperada" : "La captura no se ha recuperado; elige la cámara otra vez")
        }
    }

    var latestFrame: CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return _latest
    }

    /// Formato real del micro (canales, frecuencia): el grabador lo necesita
    /// para crear la pista de audio a juego.
    var audioFormat: CMFormatDescription? {
        lock.lock(); defer { lock.unlock() }
        return _audioFormat
    }

    var isRunning: Bool { session.isRunning }

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func requestAccess() async -> (camera: Bool, mic: Bool) {
        async let cam = AVCaptureDevice.requestAccess(for: .video)
        async let mic = AVCaptureDevice.requestAccess(for: .audio)
        return await (cam, mic)
    }

    /// Reconfigura la sesión entera y la arranca, en segundo plano. Se puede
    /// llamar las veces que haga falta: quita las entradas viejas y pone las
    /// nuevas. `completion` llega en la cola de sesión.
    func reconfigure(camera: AVCaptureDevice?, microphone: AVCaptureDevice?, completion: @escaping (Error?) -> Void) {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
            do {
                try configure(camera: camera, microphone: microphone)
                if camera != nil || microphone != nil { session.startRunning() }
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure(camera: AVCaptureDevice?, microphone: AVCaptureDevice?) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        if let camera {
            try Self.selectBestFormat(camera)
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else { throw CaptureError.cannotAdd("cámara") }
            session.addInput(input)

            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(videoOutput) else { throw CaptureError.cannotAdd("salida de vídeo") }
            session.addOutput(videoOutput)
        }

        if let microphone {
            let input = try AVCaptureDeviceInput(device: microphone)
            guard session.canAddInput(input) else { throw CaptureError.cannotAdd("micrófono") }
            session.addInput(input)
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            guard session.canAddOutput(audioOutput) else { throw CaptureError.cannotAdd("salida de audio") }
            session.addOutput(audioOutput)
        }

        lock.lock()
        _latest = nil
        _audioFormat = nil
        lock.unlock()
    }

    /// El formato más grande que llegue a 30 fps: en la OBSBOT es 3840x2160.
    private static func selectBestFormat(_ device: AVCaptureDevice) throws {
        let fps = Double(Canvas.fps)
        let candidates = device.formats.filter { format in
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps && $0.minFrameRate <= fps }
        }
        guard let best = candidates.max(by: { pixels($0) < pixels($1) }) else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = best
        let duration = CMTime(value: 1, timescale: CMTimeScale(Canvas.fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    private static func pixels(_ format: AVCaptureDevice.Format) -> Int {
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return Int(d.width) * Int(d.height)
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            lock.lock()
            _latest = pb
            lock.unlock()
        } else if output === audioOutput {
            if let fd = CMSampleBufferGetFormatDescription(sampleBuffer) {
                lock.lock()
                _audioFormat = fd
                lock.unlock()
            }
            onAudio?(sampleBuffer)
        }
    }
}

enum CaptureError: LocalizedError {
    case cannotAdd(String)
    case noWindow
    case notAuthorized(String)

    var errorDescription: String? {
        switch self {
        case .cannotAdd(let what): return "No se puede añadir \(what) a la sesión de captura."
        case .noWindow: return "No hay ninguna ventana seleccionada."
        case .notAuthorized(let what): return "Sin permiso para \(what). Actívalo en Ajustes > Privacidad y seguridad."
        }
    }
}
