import Foundation
import WebKit
import UIKit

// MARK: - 站点定义

struct SiteSpec: Identifiable {
    let id: String            // 内部标识
    let tabTitle: String      // 底栏标题
    let entry: URL            // 入口地址
    let allowedHosts: [String] // 允许在主 WebView 里开的域名（后缀匹配）
    let scriptName: String?   // 注入脚本文件名（不带 .js）
    let loginURL: URL?        // 「整页登录」用的地址（nil = 该站自带登录，不需要）
    // 登录成功后再自动回入口一次。
    // Android 侧的 HandyCode 也这么干：登录跳回来那一刻 Cookie 还没完全生效，
    // 不补这一次 reload，页面会立刻又判定「未登录」弹回登录页。
    let autoReturnAfterLogin: Bool
    let hint: String?         // 这个标签顶上常驻的一句提示

    func allows(_ url: URL?) -> Bool {
        guard let url = url, let host = url.host?.lowercased() else { return false }
        for h in allowedHosts where host == h || host.hasSuffix("." + h) {
            return true
        }
        return false
    }
}

func taobaoLogin(to target: URL) -> URL? {
    var c = URLComponents(string: "https://login.taobao.com/member/login.jhtml")
    c?.queryItems = [
        URLQueryItem(name: "style", value: "minisimple"),
        URLQueryItem(name: "redirectURL", value: target.absoluteString)
    ]
    return c?.url
}


enum Sites {
    static let pddEntry = URL(string: "https://m.pinduoduo.net/mdkd/package?tab=ID_CODE")!
    static let taobaoEntry = URL(string: "https://pages-fast.m.taobao.com/wow/z/uniapp/1100333/last-mile-fe/m-end-school-tab/home")!
    // 菜鸟官方 H5「取包裹」页 —— 就是菜鸟 App 里那个「取包裹·共N件」的网页版。
    // 它内部调 mtop.cainiao.lpc.packageservice.xiniao.querypacklist，需要淘宝登录态；
    // 未登录时会一直显示「包裹加载中…」的骨架屏。
    static let cainiaoTakeEntry = URL(string: "https://page.cainiao.com/xiniao-web/xn-h5-gg-tab-closed-takeParcel/#/")!

    static let all: [SiteSpec] = [
        SiteSpec(id: "cainiao",
                 tabTitle: "菜鸟取件",
                 entry: cainiaoTakeEntry,
                 allowedHosts: ["cainiao.com", "taobao.com", "tmall.com", "alipay.com", "alibaba.com"],
                 scriptName: "inject-taobao",
                 loginURL: taobaoLogin(to: cainiaoTakeEntry),
                 autoReturnAfterLogin: true,
                 hint: "要点「整页登录」登一次淘宝；登录后这里就是菜鸟「取包裹」原文列表")

        SiteSpec(id: "pdd",
                 tabTitle: "拼多多",
                 entry: pddEntry,
                 allowedHosts: ["pinduoduo.net", "pinduoduo.com", "yangkeduo.com"],
                 scriptName: "inject-pdd",
                 loginURL: nil,
                 autoReturnAfterLogin: false,
                 hint: nil),

        // 淘宝：官方「学校/驿站」tab，里面才是待取件**列表**。
        // 注意 end-collect-platform/identity-code 那一页只有身份码、没有包裹列表，
        // 所以聚合用的入口用这个（HandyCode 也是拿它当「待取包裹」入口）。

        SiteSpec(id: "taobao",
                 tabTitle: "淘宝取件",
                 entry: taobaoEntry,
                 allowedHosts: ["taobao.com", "tmall.com", "alipay.com", "cainiao.com", "alibaba.com"],
                 scriptName: "inject-taobao",
                 loginURL: taobaoLogin(to: taobaoEntry),
                 autoReturnAfterLogin: true,
                 hint: "登录在淘宝自己的域里完成，最不容易被回环卡住"),

        // 菜鸟「取包裹」：菜鸟 App 那个「取包裹·共N件」列表的网页版。
        // 需要淘宝登录（同一套 SessionID），所以登录走淘宝整页登录。
    ]

    // WKWebView 默认 UA 结尾是 "Mobile/15E148"，**没有 "Safari/604.1" 这一段**。
    // 阿里系的页面（淘宝登录、菜鸟取件）看到这个 UA 就认定「这是某个 App 的内嵌 WebView」，
    // 于是把登录降级成扫码/引导下载 App，登录流程根本走不完 → 于是永远未登录。
    // 拼多多不吃这套（它自己的 H5 就是给内嵌用的），所以只给淘宝/菜鸟改。
    static var safariUA: String {
        let v = UIDevice.current.systemVersion
        let uv = v.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(uv) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(v) Mobile/15E148 Safari/604.1"
    }
}

// MARK: - 每个标签一个常驻 WebView

final class WebBox: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let spec: SiteSpec
    let webView: WKWebView
    weak var store: PickupStore?
    private var opened = false
    private(set) var lastError: String?
    private var navLog: [String] = []          // 主框架导航记录（诊断用）
    private var sawLogin = false
    private var autoReturned = false

    init(spec: SiteSpec) {
        self.spec = spec
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // 登录态落盘，重启 App 不丢
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.allowsInlineMediaPlayback = true
        if let name = spec.scriptName, let js = WebBox.loadScript(name) {
            cfg.userContentController.addUserScript(
                WKUserScript(source: js,
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: false)
            )
        }
        // 聚合抓取 + 壳内修补，所有站点共用一份
        if let agent = WebBox.loadScript("pickup-agent") {
            cfg.userContentController.addUserScript(
                WKUserScript(source: agent,
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: false)
            )
        }
        let wv = WKWebView(frame: .zero, configuration: cfg)
        if spec.id != "pdd" { wv.customUserAgent = Sites.safariUA }
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        self.webView = wv
        super.init()
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.configuration.userContentController.add(self, name: "pickup")
    }

    static func loadScript(_ name: String) -> String? {
        guard let u = Bundle.main.url(forResource: name, withExtension: "js"),
              let s = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        return s
    }

    func openIfNeeded() {
        guard !opened else { return }
        opened = true
        webView.load(URLRequest(url: spec.entry))
    }

    func reload() { webView.reload() }

    func backToEntry() {
        autoReturned = false
        webView.load(URLRequest(url: spec.entry))
    }

    // 整页登录：不走页面内那个跨域 iframe，直接在当前 WebView 里打开登录页，
    // 登录完由淘宝自己 redirectURL 跳回入口。iOS 的第三方 Cookie 限制就是这么绕开的。
    func login() {
        guard let u = spec.loginURL else { return }
        sawLogin = false
        autoReturned = false
        webView.load(URLRequest(url: u))
    }

    var canLogin: Bool { spec.loginURL != nil }

    // 让页面里的脚本把「待取件」推给原生
    func collect() {
        webView.evaluateJavaScript("window.__pickupCollect && window.__pickupCollect()",
                                   completionHandler: nil)
    }

    // 诊断：页面此刻的状态、抓到的件、请求改写次数、Cookie 数量、导航链
    func diagnose(completion: @escaping (String) -> Void) {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            let mine = cookies.filter { c in
                let d = c.domain.lowercased()
                return d.contains("taobao") || d.contains("cainiao") || d.contains("alipay")
                    || d.contains("pinduoduo") || d.contains("yangkeduo")
            }
            // 只列前 14 个 cookie 名会骗人（总数 85 条，真正决定登录态的那几个可能排在第 40 位），
            // 所以改成：按域名统计 + 明确点名检查会话 cookie 在不在。
            // 注意：这里刻意拆成很多小表达式 —— 串成一条长 string 拼接会让 Swift 类型检查超时（实测踩过）。
            var byDomain: [String: Int] = [:]
            for c in mine { byDomain[c.domain.lowercased(), default: 0] += 1 }
            let sortedDomains = byDomain.sorted { $0.value > $1.value }
            var domParts: [String] = []
            for pair in sortedDomains.prefix(10) {
                domParts.append(pair.key + "=" + String(pair.value))
            }
            let doms: String = domParts.joined(separator: "  ")
            let keys: [String] = ["cookie2", "_tb_token_", "unb", "_l_g_", "sgcookie", "lgc", "tracknick", "_m_h5_tk", "cna"]
            var have: [String] = []
            var miss: [String] = []
            for k in keys {
                if mine.contains(where: { $0.name == k }) { have.append(k) } else { miss.append(k) }
            }
            let haveText: String = have.isEmpty ? "（无）" : have.joined(separator: ",")
            let missText: String = miss.isEmpty ? "（无）" : miss.joined(separator: ",")
            let domText: String = doms.isEmpty ? "（无）" : doms
            let navText: String = self.navLog.suffix(8).joined(separator: " ← ")
            var parts: [String] = []
            parts.append("cookies 总数 " + String(cookies.count) + "，相关 " + String(mine.count))
            parts.append("  按域名：" + domText)
            parts.append("  会话 cookie 有：" + haveText)
            parts.append("  缺少：" + missText)
            parts.append("nav(" + String(self.navLog.count) + "): " + navText)
            let extra: String = parts.joined(separator: "\n")
            DispatchQueue.main.async {
                self.diagnoseJS(extra: extra, completion: completion)
            }
        }
    }

    private func diagnoseJS(extra: String, completion: @escaping (String) -> Void) {
        let js = "(function(){try{return (window.__pickupDiagnostics && window.__pickupDiagnostics()) || 'no agent';}catch(e){return 'JS ERROR: '+e;}})()"
        let prefix = (lastError.map { "⚠️ \($0)\n" } ?? "") + extra + "\n"
        webView.evaluateJavaScript(js) { result, error in
            DispatchQueue.main.async {
                if let e = error {
                    completion(prefix + "evaluate 失败：\(e.localizedDescription)\n当前 URL：\(self.webView.url?.absoluteString ?? "nil")")
                } else if let s = result as? String {
                    completion(prefix + s)
                } else {
                    completion(prefix + "没有返回值（页面可能还没加载完）")
                }
            }
        }
    }

    private func noteNav(_ url: URL) {
        var s = url.absoluteString
        if s.count > 150 { s = String(s.prefix(150)) + "…" }
        navLog.append(s)
        if navLog.count > 40 { navLog.removeFirst(navLog.count - 40) }
    }

    private static func isLoginURL(_ url: URL) -> Bool {
        let s = ((url.host ?? "") + url.path + (url.query ?? "")).lowercased()
        if s.contains("/login") || s.contains("login.") || s.contains("passport") { return true }
        if s.contains("signin") || s.contains("/member/login") { return true }
        return false
    }

    var isOpened: Bool { opened }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "pickup" else { return }
        store?.ingest(message.body)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = (url.scheme ?? "").lowercased()

        if scheme == "about" || scheme == "data" || scheme == "blob" {
            decisionHandler(.allow)
            return
        }
        // 所有 http(s) 一律留在壳里开。之前把「站外 https」交给 Safari，
        // 结果一进登录流程（login.taobao.com、passport、支付宝授权页）就被踢去浏览器，
        // 那个浏览器里没有壳的登录态，等于死路。宁可多跑几张页，也不要把人踢出去。
        if scheme == "https" || scheme == "http" {
            decisionHandler(.allow)
            return
        }
        // pinduoduo:// taobao:// alipays:// 之类一律不跳转：
        // 拼多多登录页会主动往 App 里扔，跳过去就再也回不来网页登录了。
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastError = nil
        let url = webView.url
        if let u = url {
            noteNav(u)
            if spec.autoReturnAfterLogin {
                if WebBox.isLoginURL(u) {
                    sawLogin = true
                } else if sawLogin && !autoReturned {
                    // 登录成功跳回来的一瞬间，Cookie 可能还没落到 WKWebsiteDataStore，
                    // 页面脚本这会儿判「未登录」就会立刻再弹回登录页。补一次 reload，
                    // 只补一次，避免和真的登录失败无限循环。
                    autoReturned = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        guard let self = self else { return }
                        self.navLog.append("↻ 登录后自动回入口（一次性）")
                        self.webView.load(URLRequest(url: self.spec.entry))
                    }
                }
            }
        }
        collect()
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        lastError = "provisional 失败：\(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lastError = "加载失败：\(error.localizedDescription)"
    }

    // MARK: WKUIDelegate —— target=_blank / window.open 在当前 WebView 里打开

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            let s = (url.scheme ?? "").lowercased()
            if s == "http" || s == "https" || s == "about" || s == "data" || s == "blob" {
                webView.load(navigationAction.request)
            }
        }
        // 返回 nil：不要新窗口，就地加载。淘宝的验证码页靠这个才走得下去。
        return nil
    }
}
