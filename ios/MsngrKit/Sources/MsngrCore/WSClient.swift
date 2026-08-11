import Foundation
import Network

public enum WSEvent: Sendable {
    case connected
    case frame(Data)
    case disconnected
}

/// WebSocket-клиент: авто-reconnect с экспоненциальным backoff,
/// мгновенный reconnect при смене сети (NWPathMonitor), ping keepalive,
/// обнаружение мёртвого сокета по таймауту pong.
public actor WSClient {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var session: URLSession
    private var continuation: AsyncStream<WSEvent>.Continuation?
    public private(set) var isConnected = false

    private var reconnectAttempt = 0
    private var shouldRun = false
    private var pingTimer: Task<Void, Never>?
    private var awaitingPong = false
    private let pathMonitor = NWPathMonitor()
    private var lastPathStatus: NWPath.Status = .satisfied

    public init(url: URL) {
        self.url = url
        self.session = URLSession(configuration: .default)
    }

    public func events() -> AsyncStream<WSEvent> {
        AsyncStream { cont in
            self.continuation = cont
        }
    }

    public func start() {
        guard !shouldRun else { return }
        shouldRun = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.pathChanged(path.status) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "ws.path"))
        connect()
    }

    public func stop() {
        shouldRun = false
        pingTimer?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setDisconnected()
    }

    private func pathChanged(_ status: NWPath.Status) {
        let was = lastPathStatus
        lastPathStatus = status
        // wifi<->cellular или возврат сети: не ждём backoff, реконнект сразу
        if shouldRun, status == .satisfied, was != .satisfied || !isConnected {
            reconnectAttempt = 0
            reconnectNow()
        }
    }

    private func reconnectNow() {
        pingTimer?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        let wasConnected = isConnected
        setDisconnected()
        if wasConnected { continuation?.yield(.disconnected) }
        connect()
    }

    private func connect() {
        guard shouldRun, task == nil else { return }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop(t)
        // первый фрейм от сервера ("hello") подтвердит соединение
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            Task { await self.handleReceive(result, task: t) }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>, task t: URLSessionWebSocketTask) {
        guard t === task else { return } // устаревший сокет
        switch result {
        case .success(let msg):
            if !isConnected {
                isConnected = true
                reconnectAttempt = 0
                continuation?.yield(.connected)
                startPing()
            }
            switch msg {
            case .string(let s):
                handleTextFrame(s)
            case .data(let d):
                continuation?.yield(.frame(d))
            @unknown default:
                break
            }
            receiveLoop(t)
        case .failure:
            socketDied()
        }
    }

    private func handleTextFrame(_ s: String) {
        if s.contains("\"pong\"") { awaitingPong = false }
        continuation?.yield(.frame(Data(s.utf8)))
    }

    private func socketDied() {
        task?.cancel()
        task = nil
        pingTimer?.cancel()
        let wasConnected = isConnected
        setDisconnected()
        if wasConnected { continuation?.yield(.disconnected) }
        scheduleReconnect()
    }

    private func setDisconnected() {
        isConnected = false
        awaitingPong = false
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        let delay = min(pow(1.6, Double(reconnectAttempt)), 30.0)
        reconnectAttempt += 1
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self.connectIfNeeded()
        }
    }

    private func connectIfNeeded() {
        guard shouldRun, task == nil else { return }
        connect()
    }

    private func startPing() {
        pingTimer?.cancel()
        awaitingPong = false
        pingTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self else { return }
                await self.pingTick()
            }
        }
    }

    private func pingTick() {
        guard isConnected else { return }
        if awaitingPong {
            // pong не пришёл за цикл — сокет мёртв
            socketDied()
            return
        }
        awaitingPong = true
        Task { try? await self.sendRaw(Data(#"{"t":"ping"}"#.utf8)) }
    }

    public func send(_ frame: WSOutgoing) async throws {
        try await sendRaw(try frame.encode())
    }

    public func sendRaw(_ data: Data) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeRawData) }
        try await task.send(.string(text))
    }
}
