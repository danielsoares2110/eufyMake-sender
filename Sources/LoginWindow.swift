import AppKit
import WebKit

// Port of AnkerWebView: loads Anker's login page in a WKWebView and registers the
// "anker_msg" script bridge. The page posts {"functionName":...,"data":{...}} JSON to
// it; we parse login/loginback (auth token etc., fields are percent-encoded) and answer
// getHeaderList with the exact header set the native C++ build returns (AnkerNetNative
// ProcessWebScriptMessage). URL matches MainFrame.hpp m_loginUrl.

final class LoginWindowController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow?
    private var web: WKWebView?
    var onLogin: (LoginState) -> Void

    init(onLogin: @escaping (LoginState) -> Void) {
        self.onLogin = onLogin
    }

    func show() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640))
        web = webView
        let cfg = webView.configuration
        cfg.userContentController.add(self, name: "anker_msg")
        // The page expects a native-provided window.anker_msg.postMessage() bridge
        // (the wx build's AddScriptMessageHandler injects exactly this on WKWebView).
        let shim = """
        (function(){
          if (window.anker_msg) return;
          window.anker_msg = { postMessage: function(msg){
            var mh = window.webkit.messageHandlers.anker_msg;
            if (typeof msg === 'string') { mh.postMessage(msg); }
            else { mh.postMessage(JSON.stringify(msg)); }
          }};
        })();
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.navigationDelegate = self

        let nocache = String(Int(Date().timeIntervalSince1970 * 1000))
        let url = URL(string: "https://community.ankermake.com/passport-ct/?nocache=\(nocache)#/login")!
        webView.load(URLRequest(url: url))

        let w = NSWindow(contentRect: webView.frame,
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.contentView = webView
        w.isReleasedWhenClosed = false
        w.title = "Sign in with your AnkerMake account"
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        // Production community host unreachable — fall back to the QA host the
        // reference build hardcodes.
        if let url = webView.url, url.host?.contains("community.ankermake.com") == true {
            let nocache = String(Int(Date().timeIntervalSince1970 * 1000))
            if let fallback = URL(string: "https://community-qa.eufylife.com/passport-ct/?nocache=\(nocache)#/login") {
                webView.load(URLRequest(url: fallback))
            }
        }
    }

    // anker_msg bridge
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "anker_msg" else { return }

        // Body is normally a JSON string; tolerate a posted object as well.
        var root: [String: Any]?
        var rawBody: String = ""
        if let body = message.body as? String {
            rawBody = body
            if let data = body.data(using: .utf8) {
                root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                // Some pages double-encode (percent-encoded JSON inside the string).
                if root == nil, let decoded = body.removingPercentEncoding,
                   let d2 = decoded.data(using: .utf8) {
                    root = (try? JSONSerialization.jsonObject(with: d2)) as? [String: Any]
                }
            }
        } else if let dict = message.body as? [String: Any] {
            root = dict
            rawBody = (try? JSONSerialization.data(withJSONObject: dict))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        guard let root, let functionName = root["functionName"] as? String else {
            AppLog.api("login msg ignored: \(rawBody.prefix(240))")
            return
        }
        AppLog.api("login page → \(functionName)")

        if functionName == "login" || functionName == "loginback" {
            let dataDict = Self.dictionary(from: root["data"])
            let authToken = dataDict.flatMap { Self.stringField($0, ["auth_token", "authToken", "token"]) }
            let userId = dataDict.flatMap { Self.stringField($0, ["user_id", "userId", "uid"]) }
            guard let authToken, !authToken.isEmpty, let userId, !userId.isEmpty else {
                if let dataDict {
                    AppLog.api("login fields: \(dataDict.keys.sorted().joined(separator: ","))")
                }
                AppLog.api("login data unusable: \(rawBody.prefix(400))")
                return
            }
            var s = LoginState()
            s.auth_token = Self.urlDecode(authToken)
            s.user_id = Self.urlDecode(userId)
            s.email = Self.urlDecode(Self.stringField(dataDict!, ["email"]) ?? "")
            s.nick_name = Self.urlDecode(Self.stringField(dataDict!, ["nick_name", "nickname"]) ?? "")
            s.avatar = Self.urlDecode(Self.stringField(dataDict!, ["avatar"]) ?? "")
            s.ab_code = Self.urlDecode(Self.stringField(dataDict!, ["ab_code", "abCode"]) ?? "")
            s.token_expires_at = Self.stringField(dataDict!, ["token_expires_at"]) ?? ""
            s.domain = Self.urlDecode(Self.stringField(dataDict!, ["domain"]) ?? "")
            let secret = Self.dictionary(from: dataDict!["server_secret_info"])
            s.public_key = Self.stringField(secret ?? [:], ["public_key"]) ?? ""
            let doneSelf = self.onLogin
            DispatchQueue.main.async {
                doneSelf(s)
                self.window?.close()
                self.window = nil
            }
            AppLog.api("login ok, user \(s.user_id) (\(s.email))")
        } else if functionName == "getHeaderList" {
            let headers: [String: String] = [
                "Accept": "application/json, text/plain, */*",
                "Content-Type": "application/json, text/plain, */*",
                "App_name": "anker_make",
                "Model_type": "PC",
                "App_version": "14",
                "Country": "US",
                "Language": "en",
                "Openudid": "4f917785-ab9d-4ba7-9820-bbcf3d0b4e21",
                "Os_type": "Mac",
                "Os_version": "26",
            ]
            let d = try! JSONSerialization.data(withJSONObject: headers)
            let content = String(data: d, encoding: .utf8)!.replacingOccurrences(of: "\n", with: "")
            let cbName = root["callbackName"] as? String ?? ""
            let js = "window[\"\(cbName)\"]('\(content)')"
            DispatchQueue.main.async {
                self.web?.evaluateJavaScript(js)
            }
        } else if functionName == "openBrowser",
                  let url = (root["data"] as? [String: Any])?["url"] as? String,
                  let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }

    static func urlDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    // The login page is inconsistent about how it nests/encodes the payload:
    // sometimes an object, sometimes a JSON string, occasionally percent-encoded
    // (sometimes twice) and sometimes wrapped in another {"data": ...}.
    static func dictionary(from value: Any?) -> [String: Any]? {
        if let d = value as? [String: Any] {
            if let inner = d["data"] as? [String: Any], d.count == 1 { return inner }
            return d
        }
        guard var text = value as? String else { return nil }
        for _ in 0..<3 {
            if var decoded = text.removingPercentEncoding, decoded != text { text = decoded }
            if let data = text.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let inner = obj["data"] as? [String: Any], obj.count == 1 { return inner }
                return obj
            }
            break
        }
        return nil
    }

    static func stringField(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            guard let value = dict[key] else { continue }
            if let s = value as? String {
                let decoded = urlDecode(s).trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty { return decoded }
            } else if let n = value as? NSNumber {
                return n.stringValue
            }
        }
        return nil
    }
}
