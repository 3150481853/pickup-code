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

    func allows(_ url: URL?) -> Bool {
        guard let url = url, let host = url.host?.lowercased() else { return false }
        for h in allowedHosts where host == h || host.hasSuffix("." + h) {
            return true
        }
        return false
    }
}

enum Sites {
    static let all: [SiteSpec] = [
        // 拼多多：身份码 + 待取包裹（淘宝/天猫里被拼多多代收的件会出现在这里，主要是圆通）
        SiteSpec(id: "pdd",
                 tabTitle: "拼多多",
                 entry: URL(string: "https://m.pinduoduo.net/mdkd/package?tab=ID_CODE")!,
                 allowedHosts: ["pinduoduo.net", "pinduoduo.com", "yangkeduo.com"],
                 scriptName: "inject-pdd"),

        // 淘宝：官方「学校/驿站」tab，里面才是待取件**列表**。
        // 注意 end-collect-platform/identity-code 那一页只有身份码、没有包裹列表，
        // 所以聚合用的入口用这个（HandyCode 也是拿它当「待取包裹」入口）。
        SiteSpec(id: "taobao",
                 tabTitle: "淘宝取件",
                 entry: URL(string: "https://pages-fast.m.taobao.com/wow/z/uniapp/1100333/last-mile-fe/m-end-school-tab/home")!,
                 allowedHosts: ["taobao.com", "tmall.com", "alipay.com", "cainiao.com", "alibaba.com"],
                 scriptName: "inject-taobao"),

        // 菜鸟：官方身份码页，登录态与淘宝共用
        SiteSpec(id: "cainiao",
                 tabTitle: "菜鸟码",
                 entry: URL(string: "https://page.cainiao.com/cn-app-web/identity-code/index.html#/")!,
                 allowedHosts: ["cainiao.com", "taobao.com", "tmall.com", "alipay.com", "alibaba.com"],
                 scriptName: "inject-taobao")
    ]
}

// MARK: - 每个标签一个常驻 WebView

final class WebBox: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let spec: SiteSpec
    let webView: WKWebView
    weak var store: PickupStore?
    private var opened = false

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

    // 让页面里的脚本把「待取件」推给原生
    func collect() {
        webView.evaluateJavaScript("window.__pickupCollect && window.__pickupCollect()",
                                   completionHandler: nil)
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
        collect()
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
