import CoreMedia
import ScreenCaptureKit

/// Último fotograma de la ventana capturada más el rectángulo, en píxeles del
/// búfer y con origen abajo a la izquierda, que de verdad tiene contenido.
/// ScreenCaptureKit entrega el búfer del tamaño configurado aunque la ventana
/// haya cambiado de tamaño: fuera de `content` hay transparencia.
struct ScreenFrame {
    let buffer: CVPixelBuffer
    let content: CGRect
}

/// Captura de UNA ventana con ScreenCaptureKit, independiente de dónde esté o
/// de qué la tape (`desktopIndependentWindow`).
final class ScreenCapture: NSObject {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "miniobs.screen")
    private let lock = NSLock()
    private var _latest: ScreenFrame?

    /// Se llama (en la cola de captura) si la ventana desaparece o falla.
    var onStop: ((Error?) -> Void)?
    /// Se llama (una vez por arranque) cuando la ventana ha cambiado de tamaño:
    /// el stream sigue entregando el búfer del tamaño viejo, con el contenido
    /// reescalado dentro, y hay que volver a arrancarlo con el tamaño nuevo.
    var onResize: (() -> Void)?

    private var expectedScale: CGFloat = 1
    private var resizeReported = false

    var latestFrame: ScreenFrame? {
        lock.lock(); defer { lock.unlock() }
        return _latest
    }

    /// Ventanas que tiene sentido grabar: con título, en pantalla, de una app
    /// que no sea esta.
    static func windows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let me = Bundle.main.bundleIdentifier
        return content.windows
            .filter { w in
                guard let app = w.owningApplication, app.bundleIdentifier != me else { return false }
                guard let title = w.title, !title.isEmpty else { return false }
                return w.windowLayer == 0 && w.frame.width >= 200 && w.frame.height >= 200
            }
            .sorted { a, b in
                let an = a.owningApplication?.applicationName ?? ""
                let bn = b.owningApplication?.applicationName ?? ""
                return an == bn ? (a.title ?? "") < (b.title ?? "") : an < bn
            }
    }

    func start(window: SCWindow) async throws {
        await stop()

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Canvas.fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = false
        config.queueDepth = 5
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = true

        expectedScale = scale
        resizeReported = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        clear()
    }

    private func clear() {
        lock.lock()
        _latest = nil
        lock.unlock()
    }
}

extension ScreenCapture: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let status = info[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        var content = CGRect(x: 0, y: 0, width: width, height: height)
        if let dict = info[.contentRect] as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: dict),
           let scale = info[.scaleFactor] as? CGFloat {
            // contentRect viene en puntos y con origen arriba; el búfer se lee
            // en píxeles con origen abajo.
            let px = CGRect(x: rect.origin.x * scale, y: rect.origin.y * scale,
                            width: rect.width * scale, height: rect.height * scale)
            content = CGRect(x: px.origin.x, y: height - px.origin.y - px.height,
                             width: px.width, height: px.height)
                .intersection(content)
            // Si ScreenCaptureKit ha tenido que reescalar, la ventana ya no
            // mide lo que medía cuando se configuró el stream.
            if !resizeReported, abs(scale - expectedScale) > 0.01 {
                resizeReported = true
                onResize?()
            }
        }

        lock.lock()
        _latest = ScreenFrame(buffer: buffer, content: content)
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        clear()
        onStop?(error)
    }
}
