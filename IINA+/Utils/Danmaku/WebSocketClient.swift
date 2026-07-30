import Foundation

actor WebSocketClient {

    enum Event: Sendable {
        case didOpen
        case message(Data)
        case close(code: Int, reason: String?, wasClean: Bool)
        case error(String)
    }

    private var wsTask: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .ephemeral)

    // MARK: - Public API

    func open(_ url: URL) -> AsyncStream<Event> {
        Log("WebSocketClient open \(url.absoluteString)")
        let task = session.webSocketTask(with: url)
        return startStream(task: task)
    }

    func open(_ request: URLRequest) -> AsyncStream<Event> {
        Log("WebSocketClient open \(request.url?.absoluteString ?? "unknown")")
        let task = session.webSocketTask(with: request)
        return startStream(task: task)
    }

    func send(data: Data) async throws {
        try await wsTask?.send(.data(data))
    }

    func sendPing() async throws {
        try await wsTask?.sendPing(pongReceiveHandler: { _ in })
    }

    func close() {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    // MARK: - Private

    private func startStream(task: URLSessionWebSocketTask) -> AsyncStream<Event> {
        wsTask = task
        task.resume()

        return AsyncStream { continuation in
            continuation.onTermination = { _ in
                Log("WebSocketClient stream terminated")
                task.cancel()
            }
            continuation.yield(.didOpen)
            Log("WebSocketClient connected")

            Task {
                await Self.readLoop(task, continuation: continuation)
            }
        }
    }

    private static func readLoop(
        _ task: URLSessionWebSocketTask,
        continuation: AsyncStream<Event>.Continuation
    ) async {
        defer {
            Log("WebSocketClient readLoop ended")
            continuation.finish()
        }

        while true {
            do {
                let message = try await task.receive()
                switch message {
                case .data(let data):
                    continuation.yield(.message(data))
                case .string(let string):
                    if let data = string.data(using: .utf8) {
                        continuation.yield(.message(data))
                    }
                @unknown default:
                    break
                }
            } catch {
                Log("WebSocketClient error: \(error.localizedDescription)")
                continuation.yield(.error(error.localizedDescription))
                return
            }
        }
    }
}
