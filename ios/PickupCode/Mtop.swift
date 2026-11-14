import Foundation
import WebKit
import CryptoKit

// 直接在原生侧调阿里 mtop 接口。
//
// 为什么必须走原生：
//   菜鸟「取包裹」页（page.cainiao.com）要调 acs.m.taobao.com 的 mtop，
//   而 mtop 的签名 token 存在 `_m_h5_tk` 这个 **.taobao.com** 的 cookie 里。
//   网页上的 JS 在 page.cainiao.com 这个域下 **读不到 .taobao.com 的 cookie**，
//   拿不到 token 就没法签，接口只会一直回 FAIL_SYS_SESSION_EXPIRED。
//   原生侧可以从 WKHTTPCookieStore 直接取到全部 cookie，自己签、自己带 Cookie 头，
//   完全绕开「跨站读不到 cookie」这件事 —— 0.8.0 的诊断里 cookies 明明齐了却全是
//   SESSION_EXPIRED，就是这个原因。

struct MtopReply {
    let api: String
    let ret: String
    let raw: String          // data 段的 JSON（截断），诊断用
    let data: Any?           // data 段解析结果
    var ok: Bool { ret.hasPrefix("SUCCESS") }
}

enum Mtop {
    static let appKey = "12574478"

    // sign = md5(token + "&" + t + "&" + appKey + "&" + data)
    static func sign(token: String, t: String, data: String) -> String {
        let s = token + "&" + t + "&" + appKey + "&" + data
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func cookieHeader(_ all: [HTTPCookie]) -> (header: String, token: String) {
        var parts: [String] = []
        var token = ""
        for c in all where c.domain.lowercased().hasSuffix("taobao.com") {
            parts.append(c.name + "=" + c.value)
            if c.name == "_m_h5_tk" {
                token = c.value.components(separatedBy: "_").first ?? ""
            }
        }
        return (parts.joined(separator: "; "), token)
    }

    static func call(_ api: String, data: String, completion: @escaping (MtopReply) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { all in
            let ck = cookieHeader(all)
            let t = String(Int(Date().timeIntervalSince1970 * 1000))
            let sgn = sign(token: ck.token, t: t, data: data)

            var comp = URLComponents(string: "https://acs.m.taobao.com/h5/" + api + "/1.0/")
            comp?.queryItems = [
                URLQueryItem(name: "jsv", value: "2.7.2"),
                URLQueryItem(name: "appKey", value: appKey),
                URLQueryItem(name: "t", value: t),
                URLQueryItem(name: "sign", value: sgn),
                URLQueryItem(name: "api", value: api),
                URLQueryItem(name: "v", value: "1.0"),
                URLQueryItem(name: "type", value: "originaljson"),
                URLQueryItem(name: "dataType", value: "json"),
                URLQueryItem(name: "timeout", value: "20000"),
                URLQueryItem(name: "data", value: data)
            ]
            guard let u = comp?.url else {
                DispatchQueue.main.async {
                    completion(MtopReply(api: api, ret: "BAD_URL", raw: "", data: nil))
                }
                return
            }

            var req = URLRequest(url: u)
            req.httpMethod = "GET"
            req.timeoutInterval = 20
            req.setValue(ck.header, forHTTPHeaderField: "Cookie")
            req.setValue(Sites.safariUA, forHTTPHeaderField: "User-Agent")
            req.setValue("https://page.cainiao.com/", forHTTPHeaderField: "Referer")
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            URLSession.shared.dataTask(with: req) { body, resp, err in
                var reply = MtopReply(api: api, ret: "NET_EMPTY", raw: "", data: nil)
                if let e = err {
                    reply = MtopReply(api: api, ret: "NET::" + e.localizedDescription, raw: "", data: nil)
                } else if let b = body, !b.isEmpty {
                    reply = parse(api: api, body: b)
                }
                if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 {
                    reply = MtopReply(api: api, ret: "HTTP " + String(code) + " | " + reply.ret,
                                      raw: reply.raw, data: reply.data)
                }
                DispatchQueue.main.async { completion(reply) }
            }.resume()
        }
    }

    static func parse(api: String, body: Data) -> MtopReply {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            let text = String(data: body, encoding: .utf8) ?? ""
            return MtopReply(api: api, ret: "NOT_JSON", raw: String(text.prefix(300)), data: nil)
        }
        var ret = "NO_RET"
        if let arr = obj["ret"] as? [String], !arr.isEmpty {
            ret = arr.joined(separator: " | ")
        } else if let s = obj["ret"] as? String {
            ret = s
        }
        var payload: Any? = obj["data"]
        var raw = ""
        if let s = payload as? String {
            raw = s
        } else if let p = payload, let j = try? JSONSerialization.data(withJSONObject: p, options: []) {
            raw = String(data: j, encoding: .utf8) ?? ""
        }
        if raw.count > 4000 { raw = String(raw.prefix(4000)) }
        return MtopReply(api: api, ret: ret, raw: raw, data: payload)
    }
}
