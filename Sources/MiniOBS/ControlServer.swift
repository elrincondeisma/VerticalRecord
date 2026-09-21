import Foundation
import Network

/// Mando a distancia por HTTP en localhost, pensado para el Stream Deck (plugin
/// «API Request»): cada petición devuelve el estado completo en JSON, así la
/// tecla que sondea `/status` se enciende sola.
///
///   GET /status
///   GET /scene/camera   GET /scene/split
///   GET /record/start   GET /record/stop   GET /record/toggle
///   GET /windows        GET /window/<id>   GET /window/<nombre de app>   GET /window/fit   GET /window/unfit
final class ControlServer {
    typealias Handler = (String) async -> [String: Any]

    static let defaultPort: UInt16 = 8790

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "miniobs.control")
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start(port: UInt16 = ControlServer.defaultPort) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Solo en la máquina: nada de exponer el mando a la red.
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let path = request.split(separator: "\r\n").first?
                .split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            Task {
                let body = await self.handler(path.split(separator: "?").first.map(String.init) ?? path)
                let json = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
                let status = (body["error"] as? String) == "not_found" ? "404 Not Found" : "200 OK"
                var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".utf8)
                response.append(json)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }
}
