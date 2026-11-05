import Foundation
import Network
import VaultCore

final class LoopbackAssistantServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "pmv.loopback")
    private var accepting = false

    func start(handler: @escaping (String) -> String) throws -> String {
        let plan = LoopbackPlan.loopback()
        try LoopbackPlan.validate(host: plan.host)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(connection, handler: handler)
        }
        listener.start(queue: queue)
        ready.wait()
        guard let port = listener.port else {
            listener.cancel()
            throw VaultError.storageFailed
        }
        self.listener = listener
        queue.async { [weak self] in self?.accepting = true }
        return "127.0.0.1:\(port.rawValue)"
    }

    func stop() {
        queue.async { [weak self] in self?.accepting = false }
        listener?.cancel()
        listener = nil
    }

    private func receive(_ connection: NWConnection, handler: @escaping (String) -> String) {
        guard accepting else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            guard self?.isLoopback(connection) == true else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
                let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let response = DispatchQueue.main.sync { handler(raw) }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        connection.start(queue: queue)
    }

    private func isLoopback(_ connection: NWConnection) -> Bool {
        guard let endpoint = connection.currentPath?.remoteEndpoint else { return false }
        guard case .hostPort(let host, _) = endpoint else { return false }
        guard case .ipv4(let address) = host else { return false }
        return address == IPv4Address.loopback
    }
}
