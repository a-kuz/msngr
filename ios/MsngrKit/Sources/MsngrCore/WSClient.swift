import Foundation
import Network

public enum WSEvent: Sendable {
    case connected
    case frame(Data)
    case disconnected
    /// the device token no longer works (it was revoked); reconnecting has stopped
    case unauthorized
    /// The server no longer serves this build's protocol version. Reconnecting
    /// changes nothing, so the loop stops and the app states that it is behind.
    case outdated
}

/// WebSocket client: reconnects on its own with exponential backoff, reconnects
/// immediately when the network changes (NWPathMonitor), keeps the socket alive with
/// pings and spots a dead one when the pong fails to arrive.
public actor WSClient {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var session: URLSession
    private var continuation: AsyncStream<WSEvent>.Continuation?
    public private(set) var isConnected = false

    private var reconnectAttempt = 0
    /// the pending reconnect attempt: a nudge from the foreground or the network
    /// coming back cancels it so the pause is not sat out
    private var reconnectTask: Task<Void, Never>?
    private var shouldRun = false
    private var pingTimer: Task<Void, Never>?
    private var awaitingPong = false
    private let pathMonitor = NWPathMonitor()
    private var lastPathStatus: NWPath.Status = .satisfied

    /// The upgrade always carries this build's protocol version: a server that
    /// can no longer serve it answers before the socket opens into silence.
    public init(url: URL) {
        self.url = MsngrProtocol.versioned(url)
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
        reconnectTask?.cancel()
        pingTimer?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setDisconnected()
    }

    private func pathChanged(_ status: NWPath.Status) {
        let was = lastPathStatus
        lastPathStatus = status
        // wifi<->cellular, or the network coming back: reconnect now, skip the backoff
        if shouldRun, status == .satisfied, was != .satisfied || !isConnected {
            reconnectAttempt = 0
            reconnectNow()
        }
    }

    private func reconnectNow() {
        reconnectTask?.cancel()
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
        // the first frame from the server ("hello") is what confirms the connection
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            Task { await self.handleReceive(result, task: t) }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>, task t: URLSessionWebSocketTask) {
        guard t === task else { return } // a stale socket
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
            if Self.isOutdated(task: t) {
                stopForGood(.outdated)
            } else if Self.isRevoked(task: t) {
                stopForGood(.unauthorized)
            } else {
                socketDied()
            }
        }
    }

    /// Close code the server sends when the device has been revoked.
    static let revokedCloseCode = 4401

    /// Upgrade status the server answers a client below its floor with
    /// (`client_too_old`).
    static let outdatedStatus = 426

    private static func isOutdated(task: URLSessionWebSocketTask) -> Bool {
        (task.response as? HTTPURLResponse)?.statusCode == outdatedStatus
    }

    /// A revoked token reaches the client in two ways: a live socket is closed with
    /// 4401, and the next `/ws` upgrade fails authorization with 401. Either way
    /// reconnecting leads nowhere.
    private static func isRevoked(task: URLSessionWebSocketTask) -> Bool {
        if task.closeCode.rawValue == revokedCloseCode { return true }
        return (task.response as? HTTPURLResponse)?.statusCode == 401
    }

    /// A refusal no retry cures (a revoked device, a version the server dropped):
    /// the reconnect loop stops and the app decides what to show.
    private func stopForGood(_ reason: WSEvent) {
        shouldRun = false
        reconnectTask?.cancel()
        pingTimer?.cancel()
        task?.cancel()
        task = nil
        let wasConnected = isConnected
        setDisconnected()
        if wasConnected { continuation?.yield(.disconnected) }
        continuation?.yield(reason)
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

    /// Pause before attempt number `attempt`: exponential with a ceiling. The ceiling
    /// is deliberately low, because once the network is back the client has to catch up
    /// with the server within seconds.
    static func reconnectDelay(attempt: Int) -> Double {
        min(pow(1.6, Double(attempt)), 12.0)
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        let delay = Self.reconnectDelay(attempt: reconnectAttempt)
        reconnectAttempt += 1
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
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
                // 12s: presence on the server lives off ping freshness, TTL 35s
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard let self else { return }
                await self.pingTick()
            }
        }
    }

    private func pingTick() {
        guard isConnected else { return }
        if awaitingPong {
            // no pong within a cycle: the socket is dead
            socketDied()
            return
        }
        awaitingPong = true
        Task { try? await self.sendRaw(Data(#"{"t":"ping"}"#.utf8)) }
    }

    /// A nudge from the foreground: a socket that died in the background reconnects
    /// right away, a live one confirms presence with an immediate ping.
    public func nudge() {
        if task == nil {
            // a pending attempt would sit out up to 12s, so cancel it and try now
            reconnectTask?.cancel()
            reconnectAttempt = 0
            connectIfNeeded()
        } else {
            awaitingPong = false
            Task { try? await self.sendRaw(Data(#"{"t":"ping"}"#.utf8)) }
        }
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
