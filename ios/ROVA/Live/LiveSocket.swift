import Foundation

/// A push connection to the ROVA backend, so the map keeps moving without
/// anyone tapping refresh.
///
/// Why this exists: the app used to poll. Polling put the phone's own interval
/// on top of the backend's ingestion interval on top of İETT's publishing
/// cadence, and the three stacked up into minutes of lag — long enough that a
/// bus could appear to hang, go grey, and be lost. Recorded position history
/// showed the middle layer was the worst offender: unfocused lines were
/// refreshed every 420 s while İETT's own smallest gap between two distinct
/// fixes is 11–87 s.
///
/// Subscribing here is also what tells the backend which lines matter, so the
/// İETT quota is spent on the bus you are actually waiting for.
///
/// **It changes delivery, not truth.** Every fix still carries its original
/// `sourceTime`, is re-validated on arrival exactly as the REST path is, and
/// nothing is published to the app that İETT did not publish first. A socket
/// cannot make a bus report more often than it reports.
actor LiveSocket {
    static let shared = LiveSocket()

    enum State: Sendable, Equatable {
        case idle
        case connecting
        case live
        /// Dropped, with the next attempt scheduled. The app keeps polling
        /// meanwhile — a broken socket must never mean a frozen map.
        case retrying(attempt: Int)
    }

    private var task: URLSessionWebSocketTask?
    private var config: BackendClient.Config?
    private var lines: Set<String> = []
    private var attempt = 0
    private var authed = false
    private var pumping = false
    private var keepAlive: Task<Void, Never>?

    private(set) var state: State = .idle
    private(set) var lastMessageAt: Date?

    /// Called on the main actor with freshly validated vehicles for one line.
    private var onVehicles: (@Sendable (String, [Vehicle]) -> Void)?

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 0          // a socket is long-lived
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    func onVehicles(_ cb: @escaping @Sendable (String, [Vehicle]) -> Void) {
        onVehicles = cb
    }

    // MARK: lifecycle

    func configure(_ c: BackendClient.Config?) {
        guard c != config else { return }
        config = c
        disconnect()
        if c != nil, !lines.isEmpty { connect() }
    }

    /// The lines the user is travelling on. Re-subscribes if they change.
    func subscribe(to newLines: Set<String>) {
        guard !newLines.isEmpty else { return }
        let changed = newLines != lines
        lines = newLines
        if task == nil { connect() }
        else if changed { sendSubscribe() }
    }

    func disconnect() {
        keepAlive?.cancel(); keepAlive = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        authed = false
        pumping = false
        state = .idle
    }

    private func socketURL() -> URL? {
        guard let c = config, var comps = URLComponents(string: c.url) else { return nil }
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        let base = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = base + "/ws"
        return comps.url
    }

    private func connect() {
        guard config != nil, let url = socketURL(), task == nil else { return }
        state = .connecting
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        pump()
        send(["type": "auth", "token": config?.token ?? ""])
    }

    // MARK: receiving

    private func pump() {
        guard !pumping, let t = task else { return }
        pumping = true
        Task { [weak self] in
            while let self, await self.isCurrent(t) {
                do {
                    let msg = try await t.receive()
                    await self.handle(msg)
                } catch {
                    await self.dropped()
                    return
                }
            }
        }
    }

    private func isCurrent(_ t: URLSessionWebSocketTask) -> Bool { task === t }

    private func handle(_ msg: URLSessionWebSocketTask.Message) {
        lastMessageAt = Date()
        let data: Data
        switch msg {
        case .string(let s): data = Data(s.utf8)
        case .data(let d):   data = d
        @unknown default:    return
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { return }

        switch env.type {
        case "hello":
            send(["type": "auth", "token": config?.token ?? ""])
        case "auth":
            authed = env.ok ?? false
            if authed {
                attempt = 0
                state = .live
                sendSubscribe()
                startKeepAlive()
            } else {
                // A rejected token is not a transport problem; retrying it
                // just fails again. Fall back to polling and say so.
                state = .idle
                disconnect()
            }
        case "vehicles":
            guard let line = env.lineCode, let rows = env.vehicles else { return }
            let fresh = rows.compactMap { $0.toVehicle(line: line) }
            guard !fresh.isEmpty else { return }
            onVehicles?(line, fresh)
        default:
            break
        }
    }

    private func dropped() {
        guard task != nil else { return }
        task = nil
        pumping = false
        authed = false
        keepAlive?.cancel(); keepAlive = nil
        attempt += 1
        state = .retrying(attempt: attempt)
        // Back off, but come back: a dropout should be a gap of seconds, not
        // the end of tracking.
        let delay = min(30, pow(1.7, Double(min(attempt, 6))))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.reconnectIfWanted()
        }
    }

    private func reconnectIfWanted() {
        guard task == nil, config != nil, !lines.isEmpty else { return }
        connect()
    }

    /// The backend forgets a focused line after 15 minutes. A ride outlasts
    /// that, so the subscription is restated periodically.
    private func startKeepAlive() {
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.send(["type": "ping"])
            }
        }
    }

    // MARK: sending

    private func sendSubscribe() {
        guard authed else { return }
        send(["type": "subscribe", "lines": Array(lines)])
    }

    private func send(_ object: [String: Any]) {
        guard let t = task,
              let d = try? JSONSerialization.data(withJSONObject: object),
              let s = String(data: d, encoding: .utf8) else { return }
        t.send(.string(s)) { _ in }
    }

    // MARK: wire format

    private struct Envelope: Decodable {
        let type: String
        let ok: Bool?
        let lineCode: String?
        let vehicles: [Row]?
    }

    /// Re-validated on arrival. A client that trusts its server blindly is a
    /// client that will one day draw a bus in the sea.
    struct Row: Decodable {
        struct Position: Decodable { let lat: Double; let lon: Double }
        let vehicleId: String
        let patternId: String?
        let position: Position
        let sourceTime: String

        func toVehicle(line: String) -> Vehicle? {
            guard position.lat > 40.5, position.lat < 41.9,
                  position.lon > 27.0, position.lon < 30.5 else { return nil }
            guard let fix = Self.iso.date(from: sourceTime)
                    ?? Self.isoPlain.date(from: sourceTime) else { return nil }
            guard fix.timeIntervalSinceNow < 60 else { return nil }   // never from the future
            return Vehicle(doorNo: vehicleId, lat: position.lat, lon: position.lon,
                           lineCode: line, patternId: patternId ?? "",
                           lineName: "", direction: "",
                           lastFix: fix, nearStopCode: nil)
        }

        static var iso: ISO8601DateFormatter {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }
        static var isoPlain: ISO8601DateFormatter {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }
    }

    /// Exposed so the decoding path can be tested without a live socket.
    nonisolated static func decodeForTesting(_ json: String) -> [Vehicle]? {
        guard let d = json.data(using: .utf8),
              let env = try? JSONDecoder().decode(PushEnvelope.self, from: d),
              env.type == "vehicles", let line = env.lineCode else { return nil }
        return env.vehicles.compactMap { $0.toVehicle(line: line) }
    }

    struct PushEnvelope: Decodable {
        let type: String
        let lineCode: String?
        let vehicles: [Row]
    }
}
