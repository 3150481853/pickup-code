import SwiftUI
import WebKit
import UIKit

final class Boxes: ObservableObject {
    let boxes: [WebBox] = Sites.all.map { WebBox(spec: $0) }
}

struct ContentView: View {
    @StateObject private var model = Boxes()
    @State private var selected = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ForEach(Array(model.boxes.enumerated()), id: \.element.spec.id) { idx, box in
                    WebView(box: box)
                        .opacity(idx == selected ? 1 : 0)
                        .allowsHitTesting(idx == selected)
                }

                HStack(spacing: 6) {
                    chrome("刷新") { model.boxes[selected].reload() }
                    chrome("入口") { model.boxes[selected].backToEntry() }
                }
                .padding(.trailing, 10)
                .padding(.top, 6)
                .opacity(0.85)
            }

            tabBar
        }
        .onAppear { model.boxes[selected].openIfNeeded() }
        .onChange(of: selected) { idx in
            model.boxes[idx].openIfNeeded()
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
            ForEach(Array(model.boxes.enumerated()), id: \.element.spec.id) { idx, box in
                Button {
                    selected = idx
                } label: {
                    VStack(spacing: 3) {
                        Text(box.spec.tabTitle)
                            .font(.system(size: 12, weight: idx == selected ? .semibold : .regular))
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
