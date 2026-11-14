import Foundation
import Combine

// 首页聚合用的一条「待取件」
struct PickupItem: Identifiable, Hashable {
    let id: String          // 站点 + 取件码
    let site: String        // "pdd" / "taobao"
    let code: String        // 取件码，如 47-4-11026
    let station: String     // 驿站名
    let place: String       // 货架号/取件位置
    let raw: String         // 原始文本，调试与兜底展示
    let seenAt: Date
}

final class PickupStore: ObservableObject {
    @Published var items: [PickupItem] = []
    @Published var updatedAt: Date? = nil
    @Published var siteState: [String: String] = [:]   // "pdd" -> "未登录" / "已取 3 件"

    private var lastPayload: [String: [PickupItem]] = [:]

    static let siteName: [String: String] = [
        "pdd": "拼多多",
        "taobao": "淘宝/菜鸟"
    ]

    // 从注入脚本 postMessage 过来的字典里解析
    func ingest(_ body: Any) {
        guard let dict = body as? [String: Any], let site = dict["site"] as? String else { return }

        if let state = dict["state"] as? String, !state.isEmpty {
            siteState[site] = state
        }

        guard let raw = dict["items"] as? [[String: Any]] else {
            republish()
            return
        }
        var collected: [PickupItem] = []
        for r in raw {
            let code = (r["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let station = (r["station"] as? String) ?? ""
            let place = (r["place"] as? String) ?? ""
            let rawText = (r["raw"] as? String) ?? ""
            if code.isEmpty { continue }
            collected.append(PickupItem(
                id: "\(site)|\(code)",
                site: site,
                code: code,
                station: station,
                place: place,
                raw: rawText,
                seenAt: Date()
            ))
        }
        lastPayload[site] = collected
        republish()
    }

    private func republish() {
        var seen = Set<String>()
        var merged: [PickupItem] = []
        for site in ["pdd", "taobao"] {
            for it in lastPayload[site] ?? [] where !seen.contains(it.id) {
                seen.insert(it.id)
                merged.append(it)
            }
        }
        // 按取件码排：先按首段（驿站编号）再按第二段
        merged.sort { a, b in
            let (a1, a2) = PickupStore.splitCode(a.code)
            let (b1, b2) = PickupStore.splitCode(b.code)
            if a1 != b1 { return a1 < b1 }
            return a2 < b2
        }
        items = merged
        updatedAt = Date()
    }

    private static func splitCode(_ code: String) -> (Int, Int) {
        let parts = code.split(separator: "-").compactMap { Int($0) }
        if parts.count >= 2 { return (parts[0], parts[1]) }
        if let f = parts.first { return (f, 0) }
        return (9999, 9999)
    }
}
