import AVFoundation
import CoreGraphics

/// El lienzo siempre es vertical 9:16; la calidad elige cuántos píxeles.
struct Canvas: Equatable {
    let width: Int
    let height: Int

    static let fps = 30

    var rect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    var aspect: CGFloat { CGFloat(width) / CGFloat(height) }
    var label: String { "\(width)×\(height)" }
}

enum Quality: String, CaseIterable, Codable, Identifiable {
    case hd
    case uhd

    var id: String { rawValue }

    var canvas: Canvas {
        switch self {
        case .hd: return Canvas(width: 1080, height: 1920)
        case .uhd: return Canvas(width: 2160, height: 3840)
        }
    }

    var title: String {
        switch self {
        case .hd: return "1080p (1080×1920)"
        case .uhd: return "4K (2160×3840)"
        }
    }

    /// Bitrate razonable para HEVC a esta resolución; H.264 pide más.
    var defaultBitrateMbps: Int {
        switch self {
        case .hd: return 16
        case .uhd: return 50
        }
    }
}

enum Codec: String, CaseIterable, Codable, Identifiable {
    case hevc
    case h264
    case prores

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hevc: return "MP4 · HEVC (H.265)"
        case .h264: return "MP4 · H.264"
        case .prores: return "MOV · ProRes 422"
        }
    }

    var detail: String {
        switch self {
        case .hevc: return "El mejor equilibrio: ficheros pequeños, calidad alta, lo aceptan YouTube, Instagram y DaVinci."
        case .h264: return "Máxima compatibilidad; a igual calidad ocupa el doble que HEVC."
        case .prores: return "Para editar: sin pérdida visible, pero ~1 GB por minuto a 4K."
        }
    }

    var avCodec: AVVideoCodecType {
        switch self {
        case .hevc: return .hevc
        case .h264: return .h264
        case .prores: return .proRes422
        }
    }

    var fileType: AVFileType { self == .prores ? .mov : .mp4 }
    var fileExtension: String { self == .prores ? "mov" : "mp4" }
    var usesBitrate: Bool { self != .prores }
}

enum SceneKind: String, CaseIterable, Codable, Identifiable {
    case camera
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: return "Cámara"
        case .split: return "Dividida"
        }
    }

    var shortcut: String {
        switch self {
        case .camera: return "1"
        case .split: return "2"
        }
    }
}

/// Dónde va cada fuente dentro del lienzo. Los rectángulos están en coordenadas
/// de Core Image: el origen es la esquina INFERIOR izquierda, así que la
/// pantalla (arriba) tiene la `y` mayor.
struct Layout {
    var screen: CGRect?
    var camera: CGRect

    static func of(_ scene: SceneKind, in canvas: Canvas) -> Layout {
        let w = CGFloat(canvas.width)
        let h = CGFloat(canvas.height)
        switch scene {
        case .camera:
            return Layout(screen: nil, camera: CGRect(x: 0, y: 0, width: w, height: h))
        case .split:
            // 2/3 de pantalla arriba, 1/3 de cámara abajo.
            let cameraHeight = (h / 3).rounded()
            return Layout(
                screen: CGRect(x: 0, y: cameraHeight, width: w, height: h - cameraHeight),
                camera: CGRect(x: 0, y: 0, width: w, height: cameraHeight)
            )
        }
    }
}
