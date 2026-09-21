import CoreImage
import CoreVideo
import Metal

/// Compone cámara y ventana en un búfer 2160x3840 con Core Image sobre Metal.
/// Cada llamada devuelve un búfer nuevo del pool; el que lo recibe (grabador,
/// vista previa) lo retiene lo que necesite.
final class Compositor {
    let canvas: Canvas
    private let context: CIContext
    private let pool: CVPixelBufferPool
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let background: CIImage

    init(canvas: Canvas) throws {
        self.canvas = canvas
        background = CIImage(color: .black).cropped(to: canvas.rect)
        guard let device = MTLCreateSystemDefaultDevice() else { throw CompositorError.noMetal }
        context = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        ])

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: canvas.width,
            kCVPixelBufferHeightKey as String: canvas.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw CompositorError.noPool(status) }
        self.pool = pool
    }

    /// `cameraOffset` va de -1 (borde izquierdo del sensor) a 1 (derecho); 0
    /// centra. Solo actúa sobre lo que el recorte deja fuera.
    func compose(scene: SceneKind, camera: CVPixelBuffer?, screen: ScreenFrame?, cameraOffset: Double = 0) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }

        let layout = Layout.of(scene, in: canvas)
        var image = background

        if let camera {
            let ci = CIImage(cvPixelBuffer: camera)
            image = Self.fill(ci, into: layout.camera, offset: cameraOffset).composited(over: image)
        }
        if let screen, let target = layout.screen {
            // La ventana entra ENTERA: antes que perder texto por los bordes,
            // una franja negra mínima arriba y abajo.
            let ci = CIImage(cvPixelBuffer: screen.buffer).cropped(to: screen.content)
            image = Self.fit(ci, into: target).composited(over: image)
        }

        context.render(image, to: out, bounds: canvas.rect, colorSpace: colorSpace)
        return out
    }

    /// Escala para que la imagen quepa entera en `target`, centrada; lo que no
    /// cubra queda del fondo.
    private static func fit(_ image: CIImage, into target: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = min(target.width / extent.width, target.height / extent.height)
        let dx = target.minX + (target.width - extent.width * scale) / 2 - extent.minX * scale
        let dy = target.minY + (target.height - extent.height * scale) / 2 - extent.minY * scale
        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: dx, y: dy)))
            .cropped(to: target)
    }

    /// Escala para cubrir el hueco entero manteniendo la proporción (recorta lo
    /// que sobre, centrado) y deja la imagen justo dentro de `target`.
    private static func fill(_ image: CIImage, into target: CGRect, offset: Double = 0) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(target.width / extent.width, target.height / extent.height)
        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale
        let slack = target.width - scaledWidth  // negativo: lo que sobra por los lados
        let dx = target.minX + slack * (CGFloat(min(max(offset, -1), 1)) + 1) / 2 - extent.minX * scale
        let dy = target.minY + (target.height - scaledHeight) / 2 - extent.minY * scale
        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: dx, y: dy)))
            .cropped(to: target)
    }
}

enum CompositorError: LocalizedError {
    case noMetal
    case noPool(CVReturn)

    var errorDescription: String? {
        switch self {
        case .noMetal: return "Este Mac no tiene GPU Metal."
        case .noPool(let code): return "No se pudo crear el pool de búferes (\(code))."
        }
    }
}
