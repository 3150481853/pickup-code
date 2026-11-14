import SwiftUI
import WebKit
import UIKit

// MARK: - 全局模型

final class AppModel: ObservableObject {
    let store = PickupStore()
    let boxes: [WebBox]
    @Published var diag: [(String, String)] = []
    @Published private(set) var mtopNote: String = ""
    @Published private(set) var needsLogin = false
    private var timer: Timer?
    private var cainiaoTimer: Timer?

    init() {
        boxes = Sites.all.map { WebBox(spec: $0) }
        for b in boxes { b.store = store }
    }

    func startAll() {
        for b in boxes { b.openIfNeeded() }
        queryCainiao()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.collectAll()
        }
        cainiaoTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            self?.queryCainiao()
        }
    }

    // 菜鸟「取包裹」列表走原生 mtop：网页里 JS 在 page.cainiao.com 下读不到 .taobao.com 的
    // `_m_h5_tk`（签名 token），所以接口永远 SESSION_EXPIRED。原生能拿到全部 cookie。
    func queryCainiao() {
        Cainiao.query { [weak self] reply, items in
            guard let self = self else { return }
            var note = "菜鸟接口：" + reply.ret
            if reply.ok {
                note += " · " + String(items.count) + " 件"
                self.needsLogin = false
                self.store.ingestNative(site: "cainiao", items: items,
                                        state: "抓到 " + String(items.count) + " 件")
            } else {
                // 重装 / 清缓存后淘宝登录态会丢，接口就回 SESSION_EXPIRED：
                // 首页要能一眼看出来并一键去重新登录，否则只会显示「没抓到」。
                if reply.ret.contains("SESSION_EXPIRED") || reply.ret.contains("TOKEN_EMPTY")
                    || reply.ret.contains("NEED_LOGIN") {
                    self.needsLogin = true
                }
                self.store.ingestNative(site: "cainiao", items: [],
                                        state: reply.ret.components(separatedBy: "::").first ?? "失败")
                if !reply.raw.isEmpty {
                    note += "\n  " + String(reply.raw.prefix(400))
                }
            }
            self.mtopNote = note
        }
    }

    func collectAll() {
        for b in boxes where b.isOpened { b.collect() }
    }

    func refreshAll() {
        for b in boxes { b.reload() }
        queryCainiao()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.collectAll()
        }
    }

    // 把三个页面此刻的状态全拉回来，给「诊断」页看
    func diagnoseAll() {
        diag = []
        var acc: [(String, String)] = []
        let expected = boxes.count
        for b in boxes {
            let note = b.isOpened ? "" : "[这个标签还没打开过]\n"
            b.diagnose { text in
                acc.append((b.spec.tabTitle, note + text))
                if acc.count == expected {
                    self.diag = acc.sorted { $0.0 < $1.0 }
                }
            }
        }
        // 原生 mtop 这一路也记一笔：界面里网页永远显示 SESSION_EXPIRED，
        // 真正能判断「登录态到底有没有效」的是这一条。
        Cainiao.query { [weak self] reply, items in
            guard let self = self else { return }
            var t = "ret: " + reply.ret + "\n原生抓到 " + String(items.count) + " 件"
            if !items.isEmpty {
                t += "\n" + items.prefix(12).map { $0.code + " ｜ " + $0.station + " ｜ " + $0.place }.joined(separator: "\n")
            }
            // 成功也带上 raw 样本：返回结构没有文档，只能靠真数据对齐字段名
            // （0.9.0 就是因为没看过 raw，把「校园快递服务中心」当成驿站名了）。
            if !reply.raw.isEmpty { t += "\nraw: " + String(reply.raw.prefix(2000)) }
            self.diag.append(("菜鸟接口", t))
        }
    }
}

// MARK: - 根视图

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var selected = 0     // 0 = 首页，1..3 = 三个站点
    @State private var showDiag = false
    @State private var showMenu = false
    @State private var confirmClear = false

    private var titles: [String] { ["首页"] + Sites.all.map { $0.tabTitle } }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ForEach(model.boxes.indices, id: \.self) { i in
                    WebView(box: model.boxes[i])
                        .opacity(i + 1 == selected ? 1 : 0)
                        .allowsHitTesting(i + 1 == selected)
                }

                if selected == 0 {
                    HomeView(store: model.store,
                             needsLogin: model.needsLogin,
                             onRelogin: relogin,
                             onRefresh: model.refreshAll,
                             onDiagnose: {
                                 model.diagnoseAll()
                                 showDiag = true
                             })
                        .background(Color(UIColor.systemGroupedBackground))
                } else {
                    // 站点页的操作收进右下角悬浮按钮：原来右上角三个小胶囊太挤，
                    // 网页自己的顶部按钮也常被它们压住。
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            siteMenu
                        }
                    }
                    .padding(.trailing, 14)
                    .padding(.bottom, 16)
                }
            }

            if selected > 0, let hint = model.boxes[selected - 1].spec.hint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Color(UIColor.secondarySystemBackground))
            }

            tabBar
        }
        .onAppear { model.startAll() }
        .alert("清除这个站点的登录状态？", isPresented: $confirmClear) {
            Button("清除并重新登录", role: .destructive) {
                if selected > 0 { clearLogin(model.boxes[selected - 1]) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清掉 App 里这个站点的 Cookie 和网页数据，回到入口重新登录。首页已有的取件码不受影响。")
        }
        .sheet(isPresented: $showDiag) {
            DiagView(model: model, isPresented: $showDiag)
        }
    }

    // 换号用：清掉 WebView 的所有 Cookie / 本地存储，再回入口
    private func clearLogin(_ box: WebBox) {
        let dataStore = WKWebsiteDataStore.default()
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                            modifiedSince: .distantPast) {
            DispatchQueue.main.async {
                box.backToEntry()
                box.reload()
                model.diagnoseAll()
            }
        }
    }

    // 菜鸟接口回 SESSION_EXPIRED 时，从首页一键回淘宝登录页
    private func relogin() {
        guard let idx = model.boxes.firstIndex(where: { $0.spec.id == "cainiao" }) else { return }
        selected = idx + 1
        model.boxes[idx].openIfNeeded()
        model.boxes[idx].login()
    }

    // 悬浮按钮：一下展开，再一下收起，所有站点操作都从这里走
    private var siteMenu: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if showMenu {
                if selected > 0, model.boxes[selected - 1].canLogin {
                    siteButton("整页登录", "person.badge.key.fill") {
                        model.boxes[selected - 1].login()
                    }
                }
                siteButton("刷新页面", "arrow.clockwise") {
                    model.boxes[selected - 1].reload()
                }
                siteButton("回到入口", "arrow.uturn.backward") {
                    model.boxes[selected - 1].backToEntry()
                }
                siteButton("抓一次", "hand.tap.fill") {
                    model.boxes[selected - 1].collect()
                }
                siteButton("清除登录", "trash") {
                    confirmClear = true
                }
            }
            Button {
                withAnimation(.easeOut(duration: 0.16)) { showMenu.toggle() }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.62))
                        .frame(width: 50, height: 50)
                        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                    Image(systemName: showMenu ? "xmark" : "slider.horizontal.3")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private func siteButton(_ title: String, _ icon: String,
                            _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            withAnimation(.easeOut(duration: 0.16)) { showMenu = false }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func tabIcon(_ idx: Int) -> String {
        if idx == 0 { return "house.fill" }
        switch Sites.all[idx - 1].id {
        case "cainiao": return "shippingbox.fill"
        case "pdd":     return "cart.fill"
        default:        return "tag.fill"
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(titles.indices, id: \.self) { idx in
                let title = titles[idx]
                let active = idx == selected
                Button {
                    selected = idx
                    showMenu = false
                    if idx > 0 { model.boxes[idx - 1].openIfNeeded() }
                    else { model.collectAll() }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tabIcon(idx))
                            .font(.system(size: 19, weight: active ? .semibold : .regular))
                        Text(title)
                            .font(.system(size: 12, weight: active ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 9)
                    .padding(.bottom, 7)
                }
                .foregroundColor(active ? Color(red: 0.93, green: 0.14, blue: 0.30) : .secondary)
            }
        }
        .background(Color(UIColor.systemBackground))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.black.opacity(0.08)),
            alignment: .top
        )
    }
}

// MARK: - 首页：所有待取件

struct HomeView: View {
    @ObservedObject var store: PickupStore
    var needsLogin: Bool
    var onRelogin: () -> Void
    var onRefresh: () -> Void
    var onDiagnose: () -> Void

    @State private var showAdd = false
    @State private var showShare = false
    @State private var openCode: String? = nil      // 当前向左划开的那一行
    @State private var dragCode: String? = nil      // 正在拖动的那一行
    @State private var dragX: CGFloat = 0

    private let actionWidth: CGFloat = 170          // 划开后露出的两个按钮总宽

    private var subtitle: String {
        if store.items.isEmpty { return "还没有数据" }
        var s = "共 \(store.items.count) 件"
        if let t = store.updatedAt {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            s += " · \(f.string(from: t)) 更新"
        }
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("待取件")
                        .font(.system(size: 22, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                Button(action: { showAdd = true }) {
                    Text("＋ 添加")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(red: 1.0, green: 0.17, blue: 0.33).opacity(0.12))
                        .clipShape(Capsule())
                }
                .foregroundColor(Color(red: 0.85, green: 0.10, blue: 0.25))
                Button(action: onDiagnose) {
                    Text("诊断")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.05))
                        .clipShape(Capsule())
                }
                .foregroundColor(.secondary)
                Button(action: { showShare = true }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.05))
                        .clipShape(Capsule())
                }
                .foregroundColor(.secondary)
                Button(action: onRefresh) {
                    Text("刷新全部")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.07))
                        .clipShape(Capsule())
                }
                .foregroundColor(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, store.siteState.isEmpty ? 10 : 4)

            if !store.siteState.isEmpty { statusLine }

            if needsLogin { loginBanner }

            if store.items.isEmpty {
                Spacer()
                emptyView
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.items) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 28)
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddItemView(store: store)
        }
        .sheet(isPresented: $showShare) {
            SharePickerView(store: store)
        }
    }

    private var statusLine: some View {
        let parts = store.siteState
            .sorted { $0.key < $1.key }
            .map { "\(PickupStore.siteName[$0.key] ?? $0.key)：\($0.value)" }
        return Text(parts.joined(separator: "    "))
            .font(.system(size: 11))
            .foregroundColor(.secondary.opacity(0.85))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    // 菜鸟接口说「会话失效」时给一条能直接点的提示：重装 App 会清空 WKWebView 的 cookie，
    // 淘宝登录态没了，首页只会显示「没抓到」，不点这一步永远回不来。
    private var loginBanner: some View {
        Button(action: onRelogin) {
            HStack(spacing: 8) {
                Text("淘宝登录已失效，菜鸟列表拿不到 →")
                    .font(.system(size: 11))
                Text("点这里重新登录")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(Color(red: 0.85, green: 0.10, blue: 0.25))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(red: 1.0, green: 0.17, blue: 0.33).opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Text("还没有取件码")
                .font(.system(size: 15, weight: .medium))
            Text("两个来源各登录一次就行：\n「菜鸟取件」= 菜鸟的取包裹列表（要淘宝登录），\n「拼多多」= 被多多驿站代收的件。\n也可以在右上角「＋ 添加」里手动输入或截图识别。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button(action: onRefresh) {
                Text("重试")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.07))
                    .clipShape(Capsule())
            }
            .foregroundColor(.primary)
            .padding(.top, 6)
        }
        .padding(.horizontal, 34)
    }

    /// 一行待取件：向左划出「置顶 / 删除」两个按钮
    private func row(_ item: PickupItem) -> some View {
        let base: CGFloat = (openCode == item.code) ? -actionWidth : 0
        let live: CGFloat = (dragCode == item.code) ? dragX : 0
        let offset = min(0, max(-actionWidth, base + live))
        return ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Button(action: { store.togglePin(item.code); closeSwipe() }) {
                    Text(store.isPinned(item.code) ? "取消置顶" : "置顶")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: actionWidth / 2)
                        .frame(maxHeight: .infinity)
                        .background(Color(red: 0.20, green: 0.45, blue: 0.95))
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: { store.dismiss(item); closeSwipe() }) {
                    Text("删除")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: actionWidth / 2)
                        .frame(maxHeight: .infinity)
                        .background(Color(red: 0.90, green: 0.22, blue: 0.25))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            cardBody(item)
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { v in
                            // 只接管横向手势，竖向交给 ScrollView，不然首页没法上下滚
                            guard abs(v.translation.width) > abs(v.translation.height) + 4 else { return }
                            if dragCode != item.code { dragCode = item.code; dragX = 0 }
                            dragX = v.translation.width
                        }
                        .onEnded { v in
                            guard dragCode == item.code else { dragCode = nil; dragX = 0; return }
                            let dx = v.translation.width
                            if base == 0 {
                                openCode = (dx < -actionWidth * 0.35) ? item.code : nil
                            } else {
                                openCode = (dx > actionWidth * 0.25) ? nil : item.code
                            }
                            dragCode = nil
                            dragX = 0
                        }
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func closeSwipe() {
        openCode = nil
        dragCode = nil
        dragX = 0
    }

    private func cardBody(_ item: PickupItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            thumb(item)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.code)
                    .font(.system(size: 23, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                HStack(spacing: 6) {
                    Text(PickupStore.siteName[item.site] ?? item.site)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    if store.isPinned(item.code) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Color(red: 0.20, green: 0.45, blue: 0.95))
                    }
                    Text(metaText(item))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if !item.mailNo.isEmpty {
                    Text("单号 " + item.mailNo)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.9))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "doc.on.doc")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .contentShape(Rectangle())
        .onTapGesture {
            if openCode != nil { closeSwipe(); return }
            UIPasteboard.general.string = item.code
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// 左侧主图：菜鸟/拼多多给的快递图或商品图；没图时用站点图标顶一下
    private func thumb(_ item: PickupItem) -> some View {
        Thumb(item: item, side: 54)
    }

    private func metaText(_ item: PickupItem) -> String {
        var parts: [String] = []
        if !item.station.isEmpty { parts.append(item.station) }
        if !item.place.isEmpty { parts.append(item.place) }
        if parts.isEmpty { parts.append(item.raw) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 诊断页

struct DiagView: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    private var allText: String {
        model.diag.map { "### \($0.0)\n\($0.1)" }.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.diag.isEmpty {
                        Text("正在读取…（如果一直空着，说明 WebView 还没加载出页面）")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    ForEach(model.diag.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.diag[i].0)
                                .font(.system(size: 13, weight: .semibold))
                            Text(model.diag[i].1)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("全部复制") {
                        UIPasteboard.general.string = allText
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { isPresented = false }
                }
            }
        }
    }
}

// MARK: - WebView 包装

struct WebView: UIViewRepresentable {
    let box: WebBox

    func makeUIView(context: Context) -> WKWebView { box.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@main
struct PickupCodeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
