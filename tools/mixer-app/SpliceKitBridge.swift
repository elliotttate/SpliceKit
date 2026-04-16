import Foundation
import Network

/// JSON-RPC client for communicating with SpliceKit's bridge inside FCP.
/// Connects via TCP to localhost:9876 using newline-delimited JSON.
@MainActor
class SpliceKitBridge: ObservableObject {
    @Published var isConnected = false

    private var connection: NWConnection?
    private var requestID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var receiveBuffer = Data()

    private let host = NWEndpoint.Host("127.0.0.1")
    private let port = NWEndpoint.Port(rawValue: 9876)!

    func connect() {
        let conn = NWConnection(host: host, port: port, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                    self.startReceiving()
                case .failed, .cancelled:
                    self.isConnected = false
                    self.failAllPending(BridgeError.disconnected)
                default:
                    break
                }
            }
        }
        self.connection = conn
        conn.start(queue: .global(qos: .userInitiated))
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        failAllPending(BridgeError.disconnected)
    }

    /// Call a JSON-RPC method on the SpliceKit bridge.
    func call(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let connection, isConnected else {
            throw BridgeError.notConnected
        }

        requestID += 1
        let id = requestID

        var request: [String: Any] = [
            "method": method,
            "id": id
        ]
        if !params.isEmpty {
            request["params"] = params
        }

        let data = try JSONSerialization.data(withJSONObject: request)
        var line = data
        line.append(0x0A) // newline delimiter

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            connection.send(content: line, completion: .contentProcessed { [weak self] error in
                if let error {
                    Task { @MainActor in
                        self?.pending.removeValue(forKey: id)?.resume(throwing: error)
                    }
                }
            })
        }
    }

    // MARK: - Private

    private func startReceiving() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let content {
                    self.receiveBuffer.append(content)
                    self.processBuffer()
                }
                if isComplete || error != nil {
                    self.isConnected = false
                    self.failAllPending(BridgeError.disconnected)
                    return
                }
                self.startReceiving()
            }
        }
    }

    private func processBuffer() {
        while let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
            let lineData = receiveBuffer[receiveBuffer.startIndex..<newlineIndex]
            receiveBuffer = Data(receiveBuffer[receiveBuffer.index(after: newlineIndex)...])

            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            // Match response to pending request by ID
            if let id = json["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                if let error = json["error"] as? [String: Any] {
                    continuation.resume(returning: error)
                } else if let result = json["result"] as? [String: Any] {
                    continuation.resume(returning: result)
                } else {
                    // Some responses put result at top level
                    continuation.resume(returning: json)
                }
            }
            // Ignore unsolicited events/notifications for now
        }
    }

    private func failAllPending(_ error: Error) {
        let continuations = pending
        pending.removeAll()
        for (_, continuation) in continuations {
            continuation.resume(throwing: error)
        }
    }

    enum BridgeError: LocalizedError {
        case notConnected
        case disconnected

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to SpliceKit bridge"
            case .disconnected: return "Disconnected from SpliceKit bridge"
            }
        }
    }
}
