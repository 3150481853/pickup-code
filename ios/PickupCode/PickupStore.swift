import Foundation
import Combine

// 首页聚合用的一条「待取件」
struct PickupItem: Identifiable, Hashable {
    let id: String          // 站点 + 取件码
    let site: String        // "pdd" / "taobao" / "taobao-id" / "manual"
    let code: String        // 取件码，如 47-4-11026
    var station: String     // 驿站名
    var place: String       // 货架号/取件位置
    var raw: String         // 原始文本，调试与兜底展示
    let seenAt: Date
    var img: String = ""       // 左侧主图（商品图 / 快递公司图标），没取到就是空
    var mailNo: String = ""    // 快递单号，如 YT7656364590990
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

    // MARK: 已拿到 / 已出库
    /// 拿快递模式里点过的码
    @Published var picked: Set<String> = []
    /// 已归档（已取件 / 已出库）
    @Published var archived: [PickupItem] = []
    /// 这一站上次还有、这次没了 —— 记下时间，满 10 分钟才归档（驿站偶尔会漏返回一件）
    @Published var missingSince: [String: Date] = [:]
    private var archiveNotes: [String: String] = [:]
    static let missingGrace: TimeInterval = 600

    private static let manualKey = "pickup.manual.v2"
    private static let pinnedKey = "pickup.pinned.v1"
    private static let dismissedKey = "pickup.dismissed.v1"
    private static let pickedKey = "pickup.picked.v1"
    private static let archivedKey = "pickup.archived.v1"
    private static let missingKey = "pickup.missing.v1"

    /// 归档条目落盘用
    private struct ArchivedEntry: Codable {
        var code: String
        var site: String
        var station: String
        var place: String
        var mailNo: String?
        var img: String?
        var at: Date
        var note: String?
    }

    // 存档用的最小结构
    private struct ManualEntry: Codable {
        var code: String
        var station: String
        var place: String
        var seenAt: Date
        var mailNo: String? = nil
        var img: String? = nil
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
        loadArchive()
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
            let img = (r["img"] as? String) ?? ""
            let mailNo = (r["mailNo"] as? String) ?? ""
            if code.isEmpty { continue }
            collected.append(PickupItem(
                id: "\(site)|\(code)",
                site: site,
                code: code,
                station: station,
                place: place,
                raw: rawText,
                seenAt: Date(),
                img: img,
                mailNo: mailNo
            ))
        }
        reconcile(site: site, incoming: collected)
        lastPayload[site] = collected
        pruneDismissed(site)
        republish()
    }

    // 原生接口（菜鸟 mtop）整批灌进来
    func ingestNative(site: String, items: [PickupItem], state: String? = nil) {
        if let s = state, !s.isEmpty { siteState[site] = s }
        reconcile(site: site, incoming: items)
        lastPayload[site] = items
        pruneDismissed(site)
        republish()
    }

    // MARK: - 名单比对（少了 → 疑似已出库 → 10 分钟后归档）

    /// 跟这一站上一次抓到的名单比：多了的直接进首页；少了的先打「疑似已出库」标记，
    /// 过了 10 分钟仍然没回来才真归档（驿站接口偶尔会漏返回一件，不能一消失就删）。
    private func reconcile(site: String, incoming: [PickupItem]) {
        let fresh = Set(incoming.map { $0.code })
        let before = Set((lastPayload[site] ?? []).map { $0.code })
        for code in before.subtracting(fresh) where missingSince[code] == nil {
            missingSince[code] = Date()
        }
        for code in fresh {
            missingSince[code] = nil
            picked.remove(code)   // 又出现在名单里，说明没取走
        }
        saveArchive()
    }

    /// 由 AppModel 的 20 秒定时器调用：把标记超过 10 分钟的归档掉
    func archiveMissingIfNeeded() {
        guard !missingSince.isEmpty else { return }
        let cut = Date().addingTimeInterval(-PickupStore.missingGrace)
        let due = missingSince.filter { $0.value <= cut }.map { $0.key }
        guard !due.isEmpty else { return }
        for code in due {
            if let it = items.first(where: { $0.code == code }) {
                archiveNow(it, note: "疑似已出库")
            } else {
                missingSince[code] = nil
            }
        }
        saveArchive()
        republish()
    }

    func isPicked(_ code: String) -> Bool { picked.contains(code) }
    func isMissing(_ code: String) -> Bool { missingSince[code] != nil }
    /// 距归档还剩多少分钟（给列表里的小字用）
    func missingMinutesLeft(_ code: String) -> Int {
        guard let t = missingSince[code] else { return 0 }
        let left = PickupStore.missingGrace - Date().timeIntervalSince(t)
        return max(0, Int(left / 60))
    }

    func togglePicked(_ item: PickupItem) {
        if picked.contains(item.code) {
            picked.remove(item.code)
        } else {
            picked.insert(item.code)
        }
        saveArchive()
        republish()
    }

    /// 归档一条：从各站 payload / 手动里摘掉，进 archived
    func archiveNow(_ item: PickupItem, note: String = "已取件") {
        if item.manual {
            manualItems.removeAll { $0.code == item.code }
        }
        for site in Array(lastPayload.keys) {
            lastPayload[site] = (lastPayload[site] ?? []).filter { $0.code != item.code }
        }
        missingSince[item.code] = nil
        picked.remove(item.code)
        archived.removeAll { $0.code == item.code }
        archived.insert(item, at: 0)
        if archived.count > 200 { archived.removeLast(archived.count - 200) }
        archiveNotes[item.code] = note
        saveArchive()
        saveManual()
        republish()
    }

    /// 拿快递模式收工：把所有「已拿到」的批量归档
    @discardableResult
    func archivePicked() -> Int {
        let targets = items.filter { picked.contains($0.code) }
        for it in targets {
            archiveNow(it, note: "已取件")
        }
        return targets.count
    }

    /// 归档区里「放回首页」
    func restore(_ item: PickupItem) {
        archived.removeAll { $0.code == item.code }
        archiveNotes[item.code] = nil
        if item.manual {
            manualItems.removeAll { $0.code == item.code }
            manualItems.append(item)
        } else {
            var list = lastPayload[item.site] ?? []
            list.removeAll { $0.code == item.code }
            list.append(item)
            lastPayload[item.site] = list
        }
        saveArchive()
        saveManual()
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

    // MARK: - 已拿到 / 归档 落盘

    private func saveArchive() {
        let d = UserDefaults.standard
        d.set(Array(picked), forKey: PickupStore.pickedKey)
        var stamps: [String: Double] = [:]
        for (k, v) in missingSince { stamps[k] = v.timeIntervalSince1970 }
        d.set(stamps, forKey: PickupStore.missingKey)
        d.set(archiveNotes, forKey: PickupStore.archivedKey + ".notes")
        let rows: [ArchivedEntry] = archived.map { it in
            ArchivedEntry(code: it.code, site: it.site, station: it.station,
                          place: it.place, mailNo: it.mailNo, img: it.img,
                          at: it.seenAt, note: archiveNotes[it.code])
        }
        if let data = try? JSONEncoder().encode(rows) {
            d.set(data, forKey: PickupStore.archivedKey)
        }
    }

    private func loadArchive() {
        let d = UserDefaults.standard
        picked = Set((d.array(forKey: PickupStore.pickedKey) as? [String]) ?? [])
        if let raw = d.dictionary(forKey: PickupStore.missingKey) as? [String: Double] {
            var m: [String: Date] = [:]
            for (k, v) in raw { m[k] = Date(timeIntervalSince1970: v) }
            missingSince = m
        }
        archiveNotes = (d.dictionary(forKey: PickupStore.archivedKey + ".notes") as? [String: String]) ?? [:]
        guard let data = d.data(forKey: PickupStore.archivedKey),
              let rows = try? JSONDecoder().decode([ArchivedEntry].self, from: data) else { return }
        archived = rows.map { e in
            PickupItem(id: e.site + "|" + e.code, site: e.site, code: e.code,
                       station: e.station, place: e.place, raw: e.note ?? "已出库",
                       seenAt: e.at, img: e.img ?? "", mailNo: e.mailNo ?? "")
        }
    }

    func archiveNote(_ code: String) -> String {
        archiveNotes[code] ?? "已取件"
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
    func addManual(code rawCode: String, station: String = "", place: String = "",
                   mailNo: String = "") -> Bool {
        let code = PickupStore.normalize(rawCode)
        guard PickupStore.looksLikeCode(code) else { return false }
        let no = mailNo.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        manualItems.removeAll { $0.code == code }
        manualItems.append(PickupItem(
            id: "manual|\(code)",
            site: "manual",
            code: code,
            station: station.trimmingCharacters(in: .whitespacesAndNewlines),
            place: place.trimmingCharacters(in: .whitespacesAndNewlines),
            raw: "手动录入",
            seenAt: Date(),
            mailNo: no,
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
        let rows = manualItems.map { ManualEntry(code: $0.code, station: $0.station, place: $0.place,
                                                 seenAt: $0.seenAt, mailNo: $0.mailNo, img: $0.img) }
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
                       seenAt: $0.seenAt, img: $0.img ?? "", mailNo: $0.mailNo ?? "",
                       manual: true)
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
                    // 手动的优先，缺的字段用抓到的补
                    if had.station.isEmpty { had.station = it.station }
                    if had.place.isEmpty { had.place = it.place }
                    if had.img.isEmpty { had.img = it.img }
                    if had.mailNo.isEmpty { had.mailNo = it.mailNo }
                    if had.raw.isEmpty { had.raw = it.raw }
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
        // 已取/已出库的也藏起来。菜鸟接口按近 30 天返回，取走的件还会一遍遍回来，
        // 光从 lastPayload 摘掉不够 —— 下一次轮询就又灌回来了（用户看到「明明都出了还在列表里」）。
        if !archived.isEmpty {
            let gone = Set(archived.map { $0.code })
            merged = merged.filter { !gone.contains($0.code) }
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
