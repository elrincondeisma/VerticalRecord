import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Redimensiona la ventana capturada para que tenga la proporción exacta del
/// hueco de la escena dividida: así entra entera y sin franjas. Usa la API de
/// Accesibilidad, que es la única forma de tocar ventanas ajenas en macOS, y
/// por eso hace falta dar el permiso una vez.
enum WindowFitter {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Pide el permiso con el diálogo del sistema (añade la app a la lista de
    /// Accesibilidad). Devuelve si ya lo tiene.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Ajusta la ventana a `aspect` (ancho/alto). Conserva el ancho y cambia el
    /// alto; si no cabe en la pantalla, reduce el ancho. Devuelve el tamaño final.
    static func fit(_ window: SCWindow, aspect: CGFloat) throws -> CGSize {
        let axWindow = try element(for: window)
        let current = window.frame
        // Cuánto alto hay disponible desde la esquina superior de la ventana
        // hasta el borde inferior visible de su pantalla.
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: current.midX, y: flipY(current).midY)) }
        let available = screen.map { s -> CGFloat in
            let visible = s.visibleFrame
            let topInAppKit = flipY(current).maxY
            return topInAppKit - visible.minY
        } ?? .greatestFiniteMagnitude

        var width = current.width
        var height = (width / aspect).rounded()
        if height > available {
            height = available.rounded(.down)
            width = (height * aspect).rounded()
        }

        try set(axWindow, size: CGSize(width: width, height: height))
        return CGSize(width: width, height: height)
    }

    /// Devuelve la ventana al rectángulo que tenía (posición y tamaño, en
    /// coordenadas con origen arriba, como las da ScreenCaptureKit).
    static func restore(_ window: SCWindow, to frame: CGRect) throws {
        let axWindow = try element(for: window)
        var origin = frame.origin
        guard let axPos = AXValueCreate(.cgPoint, &origin) else { throw FitError.notFound }
        let moved = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, axPos)
        guard moved == .success else { throw FitError.failed(moved.rawValue) }
        try set(axWindow, size: frame.size)
    }

    private static func set(_ axWindow: AXUIElement, size: CGSize) throws {
        var size = size
        guard let axSize = AXValueCreate(.cgSize, &size) else { throw FitError.notFound }
        let result = AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, axSize)
        guard result == .success else { throw FitError.failed(result.rawValue) }
    }

    /// La ventana de Accesibilidad que corresponde a la de ScreenCaptureKit. Se
    /// casan por rectángulo: el título puede cambiar entre que se listó y ahora.
    private static func element(for window: SCWindow) throws -> AXUIElement {
        guard isTrusted else { throw FitError.notTrusted }
        guard let app = window.owningApplication else { throw FitError.noApp }
        let axApp = AXUIElementCreateApplication(app.processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else { throw FitError.noWindows }
        guard let axWindow = axWindows.first(where: { frame(of: $0)?.rounded == window.frame.rounded })
            ?? axWindows.first(where: { title(of: $0) == window.title })
        else { throw FitError.notFound }
        return axWindow
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private static func title(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    /// De coordenadas con origen arriba (ScreenCaptureKit, Accesibilidad) a
    /// AppKit (origen abajo, en la pantalla principal).
    private static func flipY(_ rect: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

private extension CGRect {
    var rounded: CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }
}

enum FitError: LocalizedError {
    case notTrusted
    case noApp
    case noWindows
    case notFound
    case failed(Int32)

    var errorDescription: String? {
        switch self {
        case .notTrusted: return "VerticalRecord necesita Accesibilidad para redimensionar ventanas: actívalo en Ajustes > Privacidad y seguridad > Accesibilidad."
        case .noApp: return "La ventana no tiene app dueña."
        case .noWindows: return "La app no expone sus ventanas por Accesibilidad."
        case .notFound: return "No encuentro esa ventana por Accesibilidad; vuelve a elegirla (↻)."
        case .failed(let code): return "La app no ha dejado cambiar el tamaño (AXError \(code))."
        }
    }
}
