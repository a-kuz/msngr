import Foundation
import Network

public enum WSEvent: Sendable {
    case connected
    case frame(Data)
    case disconnected
    /// токен устройства больше не действует (отозван); переподключение прекращено
    case unauthorized
    /// The server no longer serves this build's protocol version. Reconnecting
    /// changes nothing, so the loop stops and the app states that it is behind.
    case outdated
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
    /// отложенная попытка реконнекта: отменяется пинком из форграунда
    /// и возвратом сети, чтобы не досиживать паузу
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
        // wifi<->cellular или возврат сети: не ждём backoff, реконнект сразу
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
            if Self.isOutdated(task: t) {
                stopForGood(.outdated)
            } else if Self.isRevoked(task: t) {
                stopForGood(.unauthorized)
            } else {
                socketDied()
            }
        }
    }

    /// Код закрытия при отзыве устройства.
    static let revokedCloseCode = 4401

    /// Upgrade status the server answers a client below its floor with
    /// (`client_too_old`).
    static let outdatedStatus = 426

    private static func isOutdated(task: URLSessionWebSocketTask) -> Bool {
        (task.response as? HTTPURLResponse)?.statusCode == outdatedStatus
    }

    /// Отзыв токена сервер сообщает двумя способами: живой сокет закрывается
    /// кодом 4401, а следующая попытка апгрейда `/ws` не проходит авторизацию
    /// и отдаёт 401. Оба означают, что реконнект бессмысленен.
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

    /// Пауза перед попыткой номер attempt: экспонента с потолком.
    /// Потолок низкий: после возврата сети клиент обязан догнать сервер
    /// за секунды, а не за минуты.
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
                // 12с: presence на сервере живёт по свежести пинга (TTL 35с)
                try? await Task.sleep(nanoseconds: 12_000_000_000)
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

    /// Пинок из форграунда: мёртвый после фона сокет переподключается сразу,
    /// живой — подтверждает presence немедленным пингом.
    public func nudge() {
        if task == nil {
            // отложенная попытка досиживала бы паузу до 12с — отменяем и пробуем сразу
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
