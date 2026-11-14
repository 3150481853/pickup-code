import SwiftUI
import WebKit
import UIKit

// MARK: - 全局模型

final class AppModel: ObservableObject {
    let store = PickupStore()
    let boxes: [WebBox]
    private var timer: Timer?

    init() {
        boxes = Sites.all.map { WebBox(spec: $0) }
        for b in boxes { b.store = store }
    }

    func startAll() {
        for b in boxes { b.openIfNeeded() }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.collectAll()
        }
    }

    func collectAll() {
        for b in boxes where b.isOpened { b.collect() }
    }

    func refreshAll() {
        for b in boxes { b.reload() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.collectAll()
        }
    }
}

// MARK: - 根视图

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var selected = 0     // 0 = 首页，1..3 = 三个站点

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
                    HomeView(store: model.store, onRefresh: model.refreshAll)
                        .background(Color(UIColor.systemGroupedBackground))
                } else {
                    HStack(spacing: 6) {
                        chrome("刷新") { model.boxes[selected - 1].reload() }
                        chrome("入口") { model.boxes[selected - 1].backToEntry() }
                    }
                    .padding(.trailing, 10)
                    .padding(.top, 6)
                    .opacity(0.85)
                }
            }

            tabBar
        }
        .onAppear { model.startAll() }
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
            Text("先在下面三个标签里各登录一次：\n「拼多多」看代取的圆通件，「淘宝取件」看菜鸟那批。\n登录一次会记住，抓到的码自动汇总到这里。")
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
            Image(systemName: "doc.on.doc")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.7))
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
