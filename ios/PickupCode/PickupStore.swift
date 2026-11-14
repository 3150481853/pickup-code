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
    /// 置顶的取件码，顺序就是置顶顺序（后置顶的排后面）
    @Published var pinnedCodes: [String] = []

    private var lastPayload: [String: [PickupItem]] = [:]
    /// 被用户划走删除的码，按站点记：源里还有它就继续藏，源里没有了就自动清掉（下次同码能重新出现）
    private var dismissed: [String: [String]] = [:]

    private static let manualKey = "pickup.manual.v2"
    private static let pinnedKey = "pickup.pinned.v1"
    private static let dismissedKey = "pickup.dismissed.v1"

    // 存档用的最小结构
    private struct ManualEntry: Codable {
        var code: String
        var station: String
        var place: String
        var seenAt: Date
    }

    static let siteName: [String: String] = [
        "pdd": "拼多多",
        "cainiao": "菜鸟",
        "taobao": "淘宝/菜鸟",
        "manual": "手动"
    ]

    init() {
        loadManual()
        loadPrefs()
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
        pruneDismissed(site)
        republish()
    }

    // 原生接口（菜鸟 mtop）整批灌进来
    func ingestNative(site: String, items: [PickupItem], state: String? = nil) {
        if let s = state, !s.isEmpty { siteState[site] = s }
        lastPayload[site] = items
        pruneDismissed(site)
        republish()
    }

    // MARK: - 置顶 / 划走删除

    func isPinned(_ code: String) -> Bool {
        pinnedCodes.contains(code)
    }

    /// 置顶 / 取消置顶。置顶的排在最前，按置顶先后排。
    func togglePin(_ code: String) {
        if let i = pinnedCodes.firstIndex(of: code) {
            pinnedCodes.remove(at: i)
        } else {
            pinnedCodes.append(code)
        }
        savePrefs()
        republish()
    }

    /// 左划删除：手动录入的直接删；网页抓来的记进「划走」列表（否则下次抓取又回来）
    func dismiss(_ item: PickupItem) {
        if item.manual {
            removeManual(code: item.code)
            return
        }
        var list = dismissed[item.site] ?? []
        if !list.contains(item.code) { list.append(item.code) }
        dismissed[item.site] = list
        savePrefs()
        republish()
    }

    /// 源里已经没这个码了，就把「划走」记录清掉，免得以后同一个码再也显示不出来
    private func pruneDismissed(_ site: String) {
        guard dismissed[site] != nil else { return }
        let live = lastPayload[site]?.map { $0.code } ?? []
        if live.isEmpty {
            dismissed[site] = nil
        } else {
            let kept = (dismissed[site] ?? []).filter { live.contains($0) }
            dismissed[site] = kept.isEmpty ? nil : kept
        }
        savePrefs()
    }

    private func savePrefs() {
        UserDefaults.standard.set(pinnedCodes, forKey: PickupStore.pinnedKey)
        UserDefaults.standard.set(dismissed, forKey: PickupStore.dismissedKey)
    }

    private func loadPrefs() {
        pinnedCodes = (UserDefaults.standard.array(forKey: PickupStore.pinnedKey) as? [String]) ?? []
        dismissed = (UserDefaults.standard.dictionary(forKey: PickupStore.dismissedKey) as? [String: [String]]) ?? [:]
    }

    // MARK: - 手动 / 识别录入

    /// 规范化取件码：全角破折号→半角、去空格、字母统一大写（顺丰的是 B-13016 这种）
    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for d in ["－", "—", "–", "−", "－", "﹣", "‑"] { t = t.replacingOccurrences(of: d, with: "-") }
        t = t.replacingOccurrences(of: " ", with: "")
        t = t.replacingOccurrences(of: "\u{3000}", with: "")
        return t.uppercased()
    }

    /// 是否像取件码。两种常见形态：
    /// - 驿站/菜鸟：`122-3-12020`（数字-数字-数字[，也可能只有两段]）
    /// - 顺丰：`B-13016`（1~3 个字母 + 破折号 + 数字）
    static func looksLikeCode(_ s: String) -> Bool {
        let t = normalize(s)
        let two = "^[A-Z]{1,3}-[0-9]{1,7}$"
        let three = "^[0-9]{1,4}-[0-9]{1,7}(-[0-9]{1,7})?$"
        return t.range(of: two, options: .regularExpression) != nil
            || t.range(of: three, options: .regularExpression) != nil
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
        for site in ["cainiao", "pdd", "taobao"] {
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
        // 划走删除的藏起来（源里还在就继续藏，见 pruneDismissed）
        merged = merged.filter { it in
            guard let list = dismissed[it.site] else { return true }
            return !list.contains(it.code)
        }
        // 置顶的最前面，按置顶先后；其余按取件码排
        merged.sort { a, b in
            let pa = pinnedCodes.firstIndex(of: a.code) ?? Int.max
            let pb = pinnedCodes.firstIndex(of: b.code) ?? Int.max
            if pa != pb { return pa < pb }
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
