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
    static let cainiaoEntry = URL(string: "https://page.cainiao.com/cn-app-web/identity-code/index.html#/")!

    static let all: [SiteSpec] = [
        // 拼多多：身份码 + 待取包裹（淘宝/天猫里被拼多多代收的件会出现在这里，主要是圆通）
        SiteSpec(id: "pdd",
                 tabTitle: "拼多多",
                 entry: pddEntry,
                 allowedHosts: ["pinduoduo.net", "pinduoduo.com", "yangkeduo.com"],
                 scriptName: "inject-pdd",
                 loginURL: nil),

        // 淘宝：官方「学校/驿站」tab，里面才是待取件**列表**。
        // 注意 end-collect-platform/identity-code 那一页只有身份码、没有包裹列表，
        // 所以聚合用的入口用这个（HandyCode 也是拿它当「待取包裹」入口）。
        SiteSpec(id: "taobao",
                 tabTitle: "淘宝取件",
                 entry: taobaoEntry,
                 allowedHosts: ["taobao.com", "tmall.com", "alipay.com", "cainiao.com", "alibaba.com"],
                 scriptName: "inject-taobao",
                 loginURL: taobaoLogin(to: taobaoEntry)),

        // 菜鸟：官方身份码页，登录态与淘宝共用
        SiteSpec(id: "cainiao",
                 tabTitle: "菜鸟码",
                 entry: cainiaoEntry,
                 allowedHosts: ["cainiao.com", "taobao.com", "tmall.com", "alipay.com", "alibaba.com"],
                 scriptName: "inject-taobao",
                 loginURL: taobaoLogin(to: cainiaoEntry))
    ]
}

// MARK: - 每个标签一个常驻 WebView

final class WebBox: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let spec: SiteSpec
    let webView: WKWebView
    weak var store: PickupStore?
    private var opened = false
    private(set) var lastError: String?

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

    func backToEntry() { webView.load(URLRequest(url: spec.entry)) }

    // 整页登录：不走页面内那个跨域 iframe，直接在当前 WebView 里打开登录页，
    // 登录完由淘宝自己 redirectURL 跳回入口。iOS 的第三方 Cookie 限制就是这么绕开的。
    func login() {
        guard let u = spec.loginURL else { return }
        webView.load(URLRequest(url: u))
    }

    var canLogin: Bool { spec.loginURL != nil }

    // 让页面里的脚本把「待取件」推给原生
    func collect() {
        webView.evaluateJavaScript("window.__pickupCollect && window.__pickupCollect()",
                                   completionHandler: nil)
    }

    // 诊断：把这个页面此刻的状态、抓到的件、请求改写次数拉回来
    func diagnose(completion: @escaping (String) -> Void) {
        let js = "(function(){try{return (window.__pickupDiagnostics && window.__pickupDiagnostics()) || 'no agent';}catch(e){return 'JS ERROR: '+e;}})()"
        let prefix = lastError.map { "⚠️ \($0)\n" } ?? ""
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
        if (scheme == "https" || scheme == "http") && spec.allows(url) {
            decisionHandler(.allow)
            return
        }
        if scheme == "https" || scheme == "http" {
            // 站外 https 交给 Safari（用户协议、帮助页）
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        // pinduoduo:// taobao:// alipays:// 之类一律不跳转：
        // 拼多多登录页会主动往 App 里扔，跳过去就再也回不来网页登录了。
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastError = nil
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
        if let url = navigationAction.request.url, spec.allows(url) {
            webView.load(navigationAction.request)
        }
        // 返回 nil：不要新窗口，就地加载。淘宝的验证码页靠这个才走得下去。
        return nil
    }
}
