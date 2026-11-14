import SwiftUI
import UIKit

// 列表缩略图：自己下载、自己缩略、自己缓存。
// 之前用的是 SwiftUI 的 AsyncImage：滚动时每重建一次行就会重新发一次请求，
// 拿到 800x800 的商品图还会在主线程解，结果就是「图片正在加载的时候列表滑不动」。

final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inflight: Set<String> = []
    private let lock = NSLock()
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                diskCapacity: 80 * 1024 * 1024,
                                diskPath: "pickup-img")
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        session = URLSession(configuration: cfg)
        cache.countLimit = 160
    }

    func cached(_ url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    /// 下载 + 缩到 side*3 像素再进内存；同一地址并发只发一次
    func load(_ url: String, side: CGFloat, completion: @escaping (UIImage?) -> Void) {
        if let hit = cached(url) { completion(hit); return }
        guard let u = URL(string: url), u.scheme == "https" || u.scheme == "http" else { return }

        lock.lock()
        let busy = inflight.contains(url)
        if !busy { inflight.insert(url) }
        lock.unlock()
        if busy { return }

        var req = URLRequest(url: u)
        req.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            var img: UIImage? = nil
            if let d = data, let raw = UIImage(data: d) {
                let px = side * 3
                img = raw.preparingThumbnail(of: CGSize(width: px, height: px)) ?? raw
            }
            DispatchQueue.main.async {
                self.lock.lock()
                self.inflight.remove(url)
                self.lock.unlock()
                if let ok = img { self.cache.setObject(ok, forKey: url as NSString) }
                completion(img)
            }
        }.resume()
    }
}

/// 一条取件码的主图。空地址 / 下载失败都退回到站点图标，不占位等待。
struct Thumb: View {
    let item: PickupItem
    var side: CGFloat = 54

    @State private var image: UIImage?
    @State private var tried = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.06))
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(emoji).font(.system(size: 24))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear(perform: start)
    }

    private var emoji: String {
        item.site == "pdd" ? "🛒" : (item.site == "cainiao" ? "📦" : "🏷")
    }

    private func start() {
        guard !tried else { return }
        tried = true
        guard !item.img.isEmpty else { return }
        if let hit = ImageCache.shared.cached(item.img) {
            image = hit
            return
        }
        ImageCache.shared.load(item.img, side: side) { img in
            if let img = img { image = img }
        }
    }
}
