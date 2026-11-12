import Foundation
import CoreLocation

enum LiveError: LocalizedError {
    case transport(String)
    case soapFault(String)
    case malformed(String)
    case budgetExhausted(retryAfter: TimeInterval)
    case rateLimited(retryAfter: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .transport(let m):   return "Network problem: \(m)"
        case .soapFault(let m):   return "İETT service error: \(m)"
        case .malformed(let m):   return "Unexpected İETT response: \(m)"
        case .budgetExhausted:    return "Holding back to stay inside İETT's hourly request limit"
        case .rateLimited(let t):
            return "İETT is rate limiting this device — live positions resume in about \(Int(t / 60)) min"
        }
    }
}

/// Talks to the official İETT fleet service.
///
/// Endpoint  : https://api.ibb.gov.tr/iett/FiloDurum/SeferGerceklesme.asmx
/// Method    : GetHatOtoKonum_json(HatKodu)  → live vehicle positions for one line
/// Rate limit: the published usage document allows **100 requests per hour** to
///             this service, so every call goes through `RequestBudget`.
actor IETTLiveClient {
    static let shared = IETTLiveClient()

    private let endpoint = URL(string: "https://api.ibb.gov.tr/iett/FiloDurum/SeferGerceklesme.asmx")!
    private let action = "http://tempuri.org/GetHatOtoKonum_json"
    private let session: URLSession
    // The published ceiling is 100 requests/hour for this service. The gateway
    // answers an over-quota request with a SOAP fault reading "Policy
    // Falsified", so ROVA stays well under the line: one watched line polled at
    // the 60 s source cadence is 60 requests/hour, leaving real headroom.
    private let budget = RequestBudget(limitPerHour: 70)
    private var throttledUntil: Date?

    /// Short-lived cache so several journey options sharing a line cost one call.
    private var cache: [String: (fetched: Date, vehicles: [Vehicle])] = [:]
    private let cacheTTL: TimeInterval = 20

    private(set) var lastSuccess: Date?
    private(set) var lastError: String?
    private(set) var consecutiveFailures = 0

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["User-Agent": "ROVA/1.0 (personal transit client)"]
        session = URLSession(configuration: cfg)
    }

    var remainingRequestsThisHour: Int { budget.remaining }

    func cachedVehicles(line: String) -> [Vehicle]? {
        guard let c = cache[line], Date().timeIntervalSince(c.fetched) < 120 else { return nil }
        return c.vehicles
    }

    /// Live positions for one line code (e.g. "142").
    var isThrottled: Bool { (throttledUntil.map { $0 > Date() }) ?? false }

    func vehicles(line: String, force: Bool = false) async throws -> [Vehicle] {
        if !force, let c = cache[line], Date().timeIntervalSince(c.fetched) < cacheTTL {
            return c.vehicles
        }
        if let until = throttledUntil, until > Date() {
            if let c = cache[line] { return c.vehicles }
            throw LiveError.rateLimited(retryAfter: until.timeIntervalSinceNow)
        }
        guard budget.consume() else {
            if let c = cache[line] { return c.vehicles }
            throw LiveError.budgetExhausted(retryAfter: budget.secondsUntilSlot)
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = Self.envelope(line: line).data(using: .utf8)

        // The İETT gateway emits a sporadic 503 for an otherwise valid request,
        // so one transient failure is retried before the line is reported down.
        // The retry does not consume a second budget slot.
        var body = ""
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    throw LiveError.transport("no HTTP response")
                }
                let text = String(data: data, encoding: .utf8) ?? ""
                if http.statusCode == 200 { body = text; break }
                let fault = Self.extract(text, tag: "faultstring") ?? "HTTP \(http.statusCode)"
                // Layer7 answers an over-quota caller with "Policy Falsified".
                if fault.localizedCaseInsensitiveContains("Policy Falsified") {
                    let wait: TimeInterval = 600
                    throttledUntil = Date().addingTimeInterval(wait)
                    lastError = "İETT rate limit reached"
                    throw LiveError.rateLimited(retryAfter: wait)
                }
                if http.statusCode >= 500, attempt == 0 {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                consecutiveFailures += 1
                lastError = fault
                throw LiveError.soapFault(fault)
            } catch let e as LiveError {
                throw e
            } catch {
                if attempt == 0 {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                consecutiveFailures += 1
                lastError = error.localizedDescription
                throw LiveError.transport(error.localizedDescription)
            }
        }
        guard let payload = Self.extract(body, tag: "GetHatOtoKonum_jsonResult") else {
            consecutiveFailures += 1
            lastError = "missing result element"
            throw LiveError.malformed("missing GetHatOtoKonum_jsonResult")
        }
        let vehicles = Self.parse(json: payload, requestedLine: line)
        cache[line] = (Date(), vehicles)
        lastSuccess = Date()
        lastError = nil
        consecutiveFailures = 0
        throttledUntil = nil
        return vehicles
    }

    // MARK: SOAP plumbing

    private static func envelope(line: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:tns="http://tempuri.org/">
          <soap:Body><tns:GetHatOtoKonum_json><tns:HatKodu>\(xmlEscape(line))</tns:HatKodu></tns:GetHatOtoKonum_json></soap:Body>
        </soap:Envelope>
        """
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func extract(_ xml: String, tag: String) -> String? {
        guard let a = xml.range(of: "<\(tag)>"), let b = xml.range(of: "</\(tag)>"),
              a.upperBound <= b.lowerBound else { return nil }
        return unescape(String(xml[a.upperBound..<b.lowerBound]))
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: parsing

    static func parse(json: String, requestedLine: String) -> [Vehicle] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return raw.compactMap { r -> Vehicle? in
            func str(_ keys: String...) -> String? {
                for k in keys {
                    if let v = r[k] {
                        if let s = v as? String { let t = s.trimmingCharacters(in: .whitespaces)
                                                  if !t.isEmpty { return t } }
                        if let n = v as? NSNumber { return n.stringValue }
                    }
                }
                return nil
            }
            func num(_ keys: String...) -> Double? {
                for k in keys {
                    if let v = r[k] {
                        if let d = v as? Double { return d }
                        if let n = v as? NSNumber { return n.doubleValue }
                        if let s = v as? String {
                            let c = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                            if let d = Double(c) { return d }
                        }
                    }
                }
                return nil
            }
            guard let door = str("kapino", "KAPINO", "KapiNo"),
                  let lat = num("enlem", "ENLEM", "Enlem"),
                  let lon = num("boylam", "BOYLAM", "Boylam")
            else { return nil }
            // Reject coordinates outside greater Istanbul — the feed does emit
            // 0,0 placeholders for vehicles without a fix.
            guard lat > 40.5, lat < 41.9, lon > 27.0, lon < 30.5 else { return nil }

            let fix = parseDate(str("son_konum_zamani", "SON_KONUM_ZAMANI")) ?? Date()
            return Vehicle(doorNo: door, lat: lat, lon: lon,
                           lineCode: str("hatkodu", "HATKODU") ?? requestedLine,
                           patternId: str("guzergahkodu", "GUZERGAHKODU") ?? "",
                           lineName: str("hatad", "HATAD") ?? "",
                           direction: str("yon", "YON") ?? "",
                           lastFix: fix,
                           nearStopCode: str("yakinDurakKodu", "YAKINDURAKKODU"))
        }
    }

    private static let formats = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "dd.MM.yyyy HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss.SSS"
    ]

    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let tz = TimeZone(identifier: "Europe/Istanbul")!
        for f in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = tz
            df.dateFormat = f
            if let d = df.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }
}

/// Sliding-window request budget for the rate-limited İETT fleet service.
final class RequestBudget {
    private let limit: Int
    private var stamps: [Date] = []
    private let lock = NSLock()

    init(limitPerHour: Int) { limit = limitPerHour }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-3600)
        stamps.removeAll { $0 < cutoff }
    }

    func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        prune()
        guard stamps.count < limit else { return false }
        stamps.append(Date())
        return true
    }

    var remaining: Int {
        lock.lock(); defer { lock.unlock() }
        prune()
        return max(0, limit - stamps.count)
    }

    var secondsUntilSlot: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        prune()
        guard let oldest = stamps.first else { return 0 }
        return max(0, 3600 - Date().timeIntervalSince(oldest))
    }
}
