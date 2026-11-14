import SwiftUI
import WebKit
import UIKit

// MARK: - 全局模型

final class AppModel: ObservableObject {
    let store = PickupStore()
    let boxes: [WebBox]
    @Published var diag: [(String, String)] = []
    @Published private(set) var mtopNote: String = ""
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
                self.store.ingestNative(site: "cainiao", items: items,
                                        state: "抓到 " + String(items.count) + " 件")
            } else if !reply.raw.isEmpty {
                note += "\n  " + String(reply.raw.prefix(400))
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
                t += "\n" + items.prefix(5).map { $0.code + " " + $0.station + " " + $0.place }.joined(separator: "\n")
            }
            if !reply.ok { t += "\nraw: " + String(reply.raw.prefix(800)) }
            self.diag.append(("菜鸟接口", t))
        }
    }
}

// MARK: - 根视图

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var selected = 0     // 0 = 首页，1..3 = 三个站点
    @State private var showDiag = false

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
                             onRefresh: model.refreshAll,
                             onDiagnose: {
                                 model.diagnoseAll()
                                 showDiag = true
                             })
                        .background(Color(UIColor.systemGroupedBackground))
                } else {
                    HStack(spacing: 6) {
                        if model.boxes[selected - 1].canLogin {
                            chrome("整页登录") { model.boxes[selected - 1].login() }
                        }
                        chrome("刷新") { model.boxes[selected - 1].reload() }
                        chrome("入口") { model.boxes[selected - 1].backToEntry() }
                    }
                    .padding(.trailing, 10)
                    .padding(.top, 6)
                    .opacity(0.85)
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
        .sheet(isPresented: $showDiag) {
            DiagView(model: model, isPresented: $showDiag)
        }
    }

    private func chrome(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.06))
                .clipShape(Capsule())
        }
        .foregroundColor(.black.opacity(0.55))
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(titles.indices, id: \.self) { idx in
                let title = titles[idx]
                Button {
                    selected = idx
                    if idx > 0 { model.boxes[idx - 1].openIfNeeded() }
                    else { model.collectAll() }
                } label: {
                    VStack(spacing: 3) {
                        Text(title)
                            .font(.system(size: 11, weight: idx == selected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Circle()
                            .fill(idx == selected ? Color(red: 1.0, green: 0.17, blue: 0.33) : Color.clear)
                            .frame(width: 4, height: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 9)
                    .padding(.bottom, 6)
                }
                .foregroundColor(idx == selected ? .primary : .secondary)
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
    var onRefresh: () -> Void
    var onDiagnose: () -> Void

    @State private var showAdd = false

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

    private var emptyView: some View {
        VStack(spacing: 10) {
            Text("还没有取件码")
                .font(.system(size: 15, weight: .medium))
            Text("三个来源各登录一次就行：\n「菜鸟取件」= 菜鸟的取包裹列表（要淘宝登录），\n「拼多多」= 被多多驿站代收的件。\n也可以在右上角「＋ 添加」里手动输入或截图识别。")
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

    private func row(_ item: PickupItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
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
                    Text(metaText(item))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if item.manual {
                Button(action: { store.removeManual(code: item.code) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundColor(.secondary.opacity(0.55))
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            UIPasteboard.general.string = item.code
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
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
