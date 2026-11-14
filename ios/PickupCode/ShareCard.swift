import SwiftUI
import UIKit

/// 分享用：把选中的取件码画成一张图（不依赖 SwiftUI 渲染，iOS 15 也能用）
enum ShareCard {

    static func render(items: [PickupItem]) -> UIImage {
        let width: CGFloat = 1080
        let pad: CGFloat = 72
        let rowH: CGFloat = 170
        let listTop: CGFloat = 330
        let height = listTop + CGFloat(items.count) * rowH + 140

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { _ in
            // 背景
            UIColor(red: 0.984, green: 0.976, blue: 0.973, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()

            // 顶部红色小条
            UIColor(red: 0.85, green: 0.10, blue: 0.25, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: pad, y: 88, width: 110, height: 12),
                         cornerRadius: 6).fill()

            draw("待取件", font: .systemFont(ofSize: 76, weight: .bold),
                 color: UIColor(white: 0.08, alpha: 1), at: CGPoint(x: pad, y: 126))

            let df = DateFormatter()
            df.dateFormat = "M月d日 HH:mm"
            draw("共 \(items.count) 件 · \(df.string(from: Date()))",
                 font: .systemFont(ofSize: 34),
                 color: UIColor(white: 0.42, alpha: 1), at: CGPoint(x: pad, y: 236))

            var y = listTop
            for (i, it) in items.enumerated() {
                draw(it.code, font: .monospacedSystemFont(ofSize: 74, weight: .semibold),
                     color: UIColor(white: 0.07, alpha: 1), at: CGPoint(x: pad, y: y))

                var meta: [String] = [PickupStore.siteName[it.site] ?? it.site]
                if !it.station.isEmpty { meta.append(it.station) }
                if !it.place.isEmpty { meta.append(it.place) }
                draw(meta.joined(separator: " · "), font: .systemFont(ofSize: 32),
                     color: UIColor(white: 0.45, alpha: 1), at: CGPoint(x: pad, y: y + 90))

                if i < items.count - 1 {
                    UIColor(white: 0.90, alpha: 1).setFill()
                    UIBezierPath(rect: CGRect(x: pad, y: y + 148, width: width - pad * 2, height: 2)).fill()
                }
                y += rowH
            }

            // 页脚
            UIColor(white: 0.85, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: pad, y: y + 14, width: width - pad * 2, height: 2)).fill()
            draw("茉莉取件", font: .systemFont(ofSize: 30, weight: .medium),
                 color: UIColor(white: 0.35, alpha: 1), at: CGPoint(x: pad, y: y + 42))
            draw("取件码以驿站实际为准", font: .systemFont(ofSize: 26),
                 color: UIColor(white: 0.55, alpha: 1), at: CGPoint(x: pad, y: y + 86))
        }
    }

    private static func draw(_ text: String, font: UIFont, color: UIColor, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (text as NSString).draw(at: point, withAttributes: attrs)
    }
}

/// 系统分享面板
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// 选要分享哪几个取件码 → 生成一张图 → 调系统分享
struct SharePickerView: View {
    @ObservedObject var store: PickupStore
    @Environment(\.presentationMode) private var presentation
    @State private var picked: Set<String> = []
    @State private var shareFile: ShareFile? = nil
    @State private var didInit = false

    private var allSelected: Bool {
        !store.items.isEmpty && picked.count == store.items.count
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.items) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }

                Button(action: makeImage) {
                    Text(picked.isEmpty ? "先选至少一个" : "生成图片并分享（\(picked.count)）")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(picked.isEmpty
                                    ? Color.gray.opacity(0.4)
                                    : Color(red: 0.85, green: 0.10, blue: 0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(picked.isEmpty)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("选择要分享的取件码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { presentation.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(allSelected ? "全不选" : "全选") {
                        if allSelected {
                            picked.removeAll()
                        } else {
                            picked = Set(store.items.map { $0.code })
                        }
                    }
                }
            }
            .sheet(item: $shareFile) { f in
                ActivityView(items: [f.url])
            }
            .onAppear {
                guard !didInit else { return }
                didInit = true
                picked = Set(store.items.map { $0.code })
            }
        }
    }

    private func row(_ item: PickupItem) -> some View {
        let on = picked.contains(item.code)
        return Button(action: {
            if on { picked.remove(item.code) } else { picked.insert(item.code) }
        }) {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(on ? Color(red: 0.20, green: 0.45, blue: 0.95) : .secondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.code)
                        .font(.system(size: 19, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                    Text(([PickupStore.siteName[item.site] ?? item.site] + [item.station, item.place])
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func makeImage() {
        let chosen = store.items.filter { picked.contains($0.code) }
        guard !chosen.isEmpty else { return }
        let img = ShareCard.render(items: chosen)
        guard let data = img.pngData() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("取件码-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try data.write(to: url)
            shareFile = ShareFile(url: url)
        } catch {
            shareFile = nil
        }
    }
}
