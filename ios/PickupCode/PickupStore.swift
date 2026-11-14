import Foundation
import Combine

// 首页聚合用的一条「待取件」
struct PickupItem: Identifiable, Hashable {
    let id: String          // 站点 + 取件码
    let site: String        // "pdd" / "taobao" / "taobao-id" / "manual"
    let code: String        // 取件码，如 47-4-11026
    let station: String     // 驿站名
    let place: String       // 货架号/取件位置
    let raw: String         // 原始文本，调试与兜底展示
    let seenAt: Date
    var manual: Bool = false   // 手动录入 / 截图识别进来的
}

final class PickupStore: ObservableObject {
    @Published var items: [PickupItem] = []
    @Published var updatedAt: Date? = nil
    @Published var siteState: [String: String] = [:]   // "pdd" -> "未登录" / "已取 3 件"
    @Published var manualItems: [PickupItem] = []

    private var lastPayload: [String: [PickupItem]] = [:]

    private static let manualKey = "pickup.manual.v2"

    // 存档用的最小结构
    private struct ManualEntry: Codable {
        var code: String
        var station: String
        var place: String
        var seenAt: Date
    }

    static let siteName: [String: String] = [
        "pdd": "拼多多",
        "taobao": "淘宝/菜鸟",
        "taobao-id": "身份码",
        "manual": "手动"
    ]

    init() {
        loadManual()
        republish()
    }

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
            let code = PickupStore.normalize((r["code"] as? String) ?? "")
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

    // MARK: - 手动 / 识别录入

    /// 规范化取件码：全角破折号→半角、去空格、去首尾杂字
    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for d in ["－", "—", "–", "−", "－"] { t = t.replacingOccurrences(of: d, with: "-") }
        t = t.replacingOccurrences(of: " ", with: "")
        t = t.replacingOccurrences(of: "\u{3000}", with: "")
        return t
    }

    /// 是否像取件码（段-段-段，数字）
    static func looksLikeCode(_ s: String) -> Bool {
        let t = normalize(s)
        return t.range(of: "^[0-9]{1,4}-[0-9]{1,3}-[0-9]{1,7}$", options: .regularExpression) != nil
    }

    @discardableResult
    func addManual(code rawCode: String, station: String = "", place: String = "") -> Bool {
        let code = PickupStore.normalize(rawCode)
        guard PickupStore.looksLikeCode(code) else { return false }
        manualItems.removeAll { $0.code == code }
        manualItems.append(PickupItem(
            id: "manual|\(code)",
            site: "manual",
            code: code,
            station: station.trimmingCharacters(in: .whitespacesAndNewlines),
            place: place.trimmingCharacters(in: .whitespacesAndNewlines),
            raw: "手动录入",
            seenAt: Date(),
            manual: true
        ))
        saveManual()
        republish()
        return true
    }

    func removeManual(code: String) {
        manualItems.removeAll { $0.code == code }
        saveManual()
        republish()
    }

    private func saveManual() {
        let rows = manualItems.map { ManualEntry(code: $0.code, station: $0.station, place: $0.place, seenAt: $0.seenAt) }
        if let data = try? JSONEncoder().encode(rows) {
            UserDefaults.standard.set(data, forKey: PickupStore.manualKey)
        }
    }

    private func loadManual() {
        guard let data = UserDefaults.standard.data(forKey: PickupStore.manualKey),
              let rows = try? JSONDecoder().decode([ManualEntry].self, from: data) else { return }
        manualItems = rows.map {
            PickupItem(id: "manual|\($0.code)", site: "manual", code: $0.code,
                       station: $0.station, place: $0.place, raw: "手动录入",
                       seenAt: $0.seenAt, manual: true)
        }
    }

    // MARK: - 汇总

    private func republish() {
        // 同一个取件码只留一条：手动录入优先（用户确认过），缺的驿站/货位再用抓到的补
        var order: [String] = []
        var byCode: [String: PickupItem] = [:]

        for it in manualItems where byCode[it.code] == nil {
            byCode[it.code] = it
            order.append(it.code)
        }
        for site in ["pdd", "taobao"] {
            for it in lastPayload[site] ?? [] {
                if var had = byCode[it.code] {
                    if had.station.isEmpty && !it.station.isEmpty { had = PickupItem(id: had.id, site: had.site, code: had.code, station: it.station, place: had.place, raw: had.raw, seenAt: had.seenAt, manual: had.manual) }
                    if had.place.isEmpty && !it.place.isEmpty { had = PickupItem(id: had.id, site: had.site, code: had.code, station: had.station, place: it.place, raw: had.raw, seenAt: had.seenAt, manual: had.manual) }
                    byCode[it.code] = had
                } else {
                    byCode[it.code] = it
                    order.append(it.code)
                }
            }
        }

        var merged = order.compactMap { byCode[$0] }
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
