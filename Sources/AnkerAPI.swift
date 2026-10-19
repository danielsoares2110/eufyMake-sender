import Foundation
import CryptoKit

// Minimal logger that mirrors the C++ stderr logs (visible in Console if run from a
// terminal: ./EufyMake Sender.app/Contents/MacOS/EufyMakeSender).
enum AppLog {
    static var lines: [String] { buf.reversed() }
    static func onLine(_ f: @escaping (String) -> Void) { callback = f }

    private static var buf: [String] = []
    private static var callback: ((String) -> Void)?
    private static let q = DispatchQueue(label: "m5.log")

    static func put(_ tag: String, _ msg: String) {
        let line = "[\(tag)] \(msg)"
        q.async {
            buf.insert(line, at: 0)
            if buf.count > 400 { buf.removeLast(buf.count - 400) }
            print(line)
            callback?(line)
        }
    }
    static func pppp(_ m: String) { put("Pppp", m) }
    static func mqtt(_ m: String) { put("MQTT", m) }
    static func net(_ m: String) { put("Net", m) }
    static func api(_ m: String) { put("API", m) }
    static func video(_ m: String) { put("H264", m) }
}

// Login state + cache (ankernet_native_login.json equivalents), and the cloud REST
// calls: query_fdm_list → devices (station_sn, secret_key, p2p_did, ...).

struct LoginState: Codable {
    var auth_token: String = ""
    var user_id: String = ""
    var email: String = ""
    var nick_name: String = ""
    var avatar: String = ""
    var ab_code: String = ""
    var token_expires_at: String = ""
    var domain: String = ""
    var public_key: String = ""

    var isLogined: Bool { !auth_token.isEmpty && !user_id.isEmpty }

    var apiBase: String {
        if !domain.isEmpty { return "https://" + domain }
        if ab_code.lowercased() == "eu" { return "https://make-app-eu.ankermake.com" }
        return "https://make-app.ankermake.com"
    }
    var mqttHost: String {
        // The reference client selects the broker purely by account region (ab_code).
        if ab_code.lowercased() == "eu" { return "make-mqtt-eu.ankermake.com" }
        return "make-mqtt.ankermake.com"
    }
}

final class AnkerAPI {
    func loadLogin() -> LoginState {
        let path = Self.loginCachePath()
        guard let data = FileManager.default.contents(atPath: path) else { return LoginState() }
        return (try? JSONDecoder().decode(LoginState.self, from: data)) ?? LoginState()
    }

    func saveLogin(_ s: LoginState) {
        let path = Self.loginCachePath()
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) {
            try? d.write(to: URL(fileURLWithPath: path))
        }
    }

    static func loginCachePath() -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("EufyMakeSender/login.json").path
    }
}

struct AnkerDevice: Identifiable, Equatable, Hashable {
    let sn: String
    let name: String
    let model: String
    let ip: String
    let secretKey: String
    let p2pDid: String
    let p2pConn: String

    var id: String { sn }
}

extension AnkerAPI {
    struct ApiError: Error { let message: String }

    func queryDeviceList(_ login: LoginState) async throws -> [AnkerDevice] {
        let resp = try await httpPostV1(login, path: "/v1/app/query_fdm_list", body: "{}")
        let json = try JSONSerialization.jsonObject(with: Data(resp.utf8)) as? [String: Any] ?? [:]
        guard (json["code"] as? Int ?? -1) == 0 else {
            throw ApiError(message: "query_fdm_list code=\(json["code"] ?? "?") msg=\(json["msg"] ?? "")")
        }
        // `data` is normally an array; tolerate an object keyed by serial too.
        var rows: [[String: Any]] = []
        if let arr = json["data"] as? [[String: Any]] {
            rows = arr
        } else if let dict = json["data"] as? [String: Any] {
            rows = dict.values.compactMap { $0 as? [String: Any] }
        }
        var devices: [AnkerDevice] = []
        for d in rows {
            let sn = d["station_sn"] as? String ?? ""
            guard !sn.isEmpty else { continue }
            devices.append(AnkerDevice(
                sn: sn,
                name: d["station_name"] as? String ?? "",
                model: d["station_model"] as? String ?? "",
                ip: d["ip_addr"] as? String ?? "",
                secretKey: d["secret_key"] as? String ?? "",
                p2pDid: d["p2p_did"] as? String ?? "",
                p2pConn: d["p2p_conn"] as? String ?? ""))
        }
        return devices
    }

    func httpPostV1(_ login: LoginState, path: String, body: String) async throws -> String {
        let md5hex = Insecure.MD5.hash(data: Data(login.user_id.utf8))
            .map { String(format: "%02x", $0) }.joined()
        var req = URLRequest(url: URL(string: login.apiBase + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.httpBody = Data(body.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(login.auth_token, forHTTPHeaderField: "X-Auth-Token")
        req.setValue(md5hex, forHTTPHeaderField: "Gtoken")
        req.setValue("anker_make", forHTTPHeaderField: "App_name")
        req.setValue("PC", forHTTPHeaderField: "Model_type")
        req.setValue("14", forHTTPHeaderField: "App_version")
        req.setValue("US", forHTTPHeaderField: "Country")
        req.setValue("en", forHTTPHeaderField: "Language")
        req.setValue("Mac", forHTTPHeaderField: "Os_type")
        req.setValue("26", forHTTPHeaderField: "Os_version")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ApiError(message: "no response") }
        if http.statusCode < 200 || http.statusCode >= 300 {
            throw ApiError(message: "POST \(path) → \(http.statusCode) \(String(data: data, encoding: .utf8) ?? "")")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
