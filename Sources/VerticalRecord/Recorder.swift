import AVFoundation
import CoreMedia
import VideoToolbox

/// Escribe el lienzo compuesto y el audio del micro a un MP4 con HEVC por
/// hardware. Los tiempos son los del reloj del host, que es el que usan tanto
/// AVCaptureSession como el temporizador de composición.
final class Recorder {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let lock = NSLock()
    private var sessionStart: CMTime?
    private(set) var droppedFrames = 0

    init(url: URL, canvas: Canvas, codec: Codec, bitrateMbps: Int, audioFormat: CMFormatDescription?) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: codec.fileType)

        var video: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: canvas.width,
            AVVideoHeightKey: canvas.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if codec.usesBitrate {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrateMbps * 1_000_000,
                AVVideoExpectedSourceFrameRateKey: Canvas.fps,
                AVVideoMaxKeyFrameIntervalKey: Canvas.fps * 2,
            ]
            compression[AVVideoProfileLevelKey] = codec == .hevc
                ? kVTProfileLevel_HEVC_Main_AutoLevel as String
                : AVVideoProfileLevelH264HighAutoLevel
            video[AVVideoCompressionPropertiesKey] = compression
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: video)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: canvas.width,
            kCVPixelBufferHeightKey as String: canvas.height,
        ])
        guard writer.canAdd(videoInput) else { throw RecorderError.cannotAdd("vídeo") }
        writer.add(videoInput)

        // La pista de audio se crea a juego con el micro (canales y frecuencia);
        // si aún no ha sonado nada, se graba sin audio antes que fallar.
        if let audioFormat, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee {
            let channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
            let audio: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 128_000 : 192_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audio, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.cannotAdd("audio") }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else {
            throw RecorderError.writer(writer.error?.localizedDescription ?? "startWriting falló")
        }
    }

    var hasAudio: Bool { audioInput != nil }

    /// El primer fotograma fija el origen de tiempos; el audio anterior a ese
    /// instante se descarta, porque el escritor no lo aceptaría.
    func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard writer.status == .writing else { return }
        if sessionStart == nil {
            writer.startSession(atSourceTime: time)
            sessionStart = time
        }
        guard videoInput.isReadyForMoreMediaData else { droppedFrames += 1; return }
        if !adaptor.append(buffer, withPresentationTime: time) { droppedFrames += 1 }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let audioInput, writer.status == .writing, let start = sessionStart else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sample) >= start else { return }
        guard audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sample)
    }

    func finish() async throws {
        let status = markFinished()
        guard status == .writing else {
            throw RecorderError.writer(writer.error?.localizedDescription ?? "estado \(status.rawValue)")
        }
        await writer.finishWriting()
        if writer.status == .failed {
            throw RecorderError.writer(writer.error?.localizedDescription ?? "finishWriting falló")
        }
    }

    private func markFinished() -> AVAssetWriter.Status {
        lock.lock(); defer { lock.unlock() }
        let status = writer.status
        if status == .writing {
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
        }
        return status
    }

    var error: Error? { writer.error }
}

enum RecorderError: LocalizedError {
    case cannotAdd(String)
    case writer(String)

    var errorDescription: String? {
        switch self {
        case .cannotAdd(let what): return "No se puede añadir la pista de \(what)."
        case .writer(let why): return "Error al escribir el vídeo: \(why)"
        }
    }
}
