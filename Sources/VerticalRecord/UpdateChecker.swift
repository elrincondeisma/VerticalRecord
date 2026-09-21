import AppKit
import Foundation

/// Aviso de versiones nuevas sin dependencias: pregunta a GitHub por la última
/// release, compara con la versión del bundle y ofrece descargar el DMG. La
/// instalación sigue siendo manual (arrastrar a Aplicaciones), a propósito:
/// nada de instaladores en segundo plano.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String
        let pageURL: URL
        let dmgURL: URL?
        let notes: String
    }

    /// Versión nueva disponible (más alta que la instalada y no omitida).
    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    @Published private(set) var lastResult: String?

    static let api = URL(string: "https://api.github.com/repos/elrincondeisma/VerticalRecord/releases/latest")!
    static let interval: TimeInterval = 24 * 60 * 60

    private let defaults = UserDefaults.standard
    private let lastCheckKey = "update.lastCheck"
    private let skippedKey = "update.skippedVersion"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Comprobación silenciosa al arrancar: solo si ha pasado un día desde la
    /// última y sin molestar si no hay nada.
    func checkIfDue() {
        let last = defaults.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.interval else { return }
        Task { await check(manual: false) }
    }

    /// Comprobación pedida por el usuario: informa siempre del resultado.
    func checkNow() {
        Task { await check(manual: true) }
    }

    func skip(_ release: Release) {
        defaults.set(release.version, forKey: skippedKey)
        available = nil
    }

    func download(_ release: Release) {
        NSWorkspace.shared.open(release.dmgURL ?? release.pageURL)
    }

    private func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            var request = URLRequest(url: Self.api)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("VerticalRecord/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            else { throw UpdateError.badResponse }
            defaults.set(Date(), forKey: lastCheckKey)

            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            let dmg = assets
                .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
            let release = Release(version: version, pageURL: page, dmgURL: dmg, notes: json["body"] as? String ?? "")

            if Self.isNewer(version, than: currentVersion) {
                let skipped = defaults.string(forKey: skippedKey)
                if manual || skipped != version {
                    available = release
                }
                lastResult = "Hay una versión nueva: \(version)"
                if manual { presentAlert(for: release) }
            } else {
                available = nil
                lastResult = "Tienes la última versión (\(currentVersion))"
                if manual { presentUpToDate() }
            }
        } catch {
            lastResult = "No se pudo comprobar: \(error.localizedDescription)"
            if manual { presentError(error) }
        }
    }

    /// Compara versiones numéricas por componentes: 1.10.0 > 1.9.2.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Diálogos (solo en la comprobación manual)

    private func presentAlert(for release: Release) {
        let alert = NSAlert()
        alert.messageText = "VerticalRecord \(release.version) está disponible"
        alert.informativeText = "Tienes la \(currentVersion). Descarga el DMG y arrastra la app a Aplicaciones para actualizar."
            + (release.notes.isEmpty ? "" : "\n\n" + Self.summary(of: release.notes))
        alert.addButton(withTitle: "Descargar")
        alert.addButton(withTitle: "Ver novedades")
        alert.addButton(withTitle: "Más tarde")
        switch alert.runModal() {
        case .alertFirstButtonReturn: download(release)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.pageURL)
        default: break
        }
    }

    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "Tienes la última versión"
        alert.informativeText = "VerticalRecord \(currentVersion) es la versión más reciente."
        alert.runModal()
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "No se pudo comprobar si hay actualizaciones"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    /// Las notas de la release en Markdown, reducidas a las primeras líneas de texto.
    private static func summary(of notes: String) -> String {
        notes.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("SHA-256") }
            .prefix(4)
            .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "") }
            .joined(separator: "\n")
    }
}

enum UpdateError: LocalizedError {
    case badResponse
    var errorDescription: String? { "GitHub ha devuelto una respuesta que no entiendo." }
}
