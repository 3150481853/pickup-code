import Foundation

// 菜鸟「取包裹」的数据接口（菜鸟 App 首页那个「取包裹·共 N 件」就是它）。
// 走原生 mtop（见 Mtop.swift），不依赖网页。
// 返回结构没有公开文档，所以这里不硬编码字段名，直接递归扫 JSON：
// 取件码的形状太独特（数字-数字-数字），扫到就是要的那一条，
// 驿站名 / 货位再从同一个对象里的兄弟字段里挑。
enum Cainiao {
    static let queryApi = "mtop.cainiao.lpc.packageservice.xiniao.querypacklist"

    static func query(completion: @escaping (MtopReply, [PickupItem]) -> Void) {
        // staId 传空 = 所有驿站; day=30 取近 30 天; needAuthControl 要走登录态
        let payload = "{\"staId\":\"\",\"day\":30,\"needAuthControl\":true}"
        Mtop.call(queryApi, data: payload) { reply in
            let items = reply.ok ? Parser.items(from: reply.data) : []
            completion(reply, items)
        }
    }

    enum Parser {
        static func isCode(_ s: String) -> Bool {
            let t = PickupStore.normalize(s)
            guard t.count >= 5, t.count <= 18 else { return false }
            // 比 PickupStore.looksLikeCode 更严：JSON 里满地都是 "2026-11" 这种日期，
            // 末段必须 3 位以上；顺丰形态要求前面的数字段 ≥3 位。
            let strict = "^(?:[A-Z]{1,3}-[0-9]{3,7}|[0-9]{1,4}-[0-9]{3,7}|[0-9]{1,3}-[0-9]{1,3}-[0-9]{3,7})$"
            return t.range(of: strict, options: .regularExpression) != nil
        }

        // 地址比驿站名长得多、还带省市区镇：一律不算驿站名。
        static func looksLikeAddress(_ s: String) -> Bool {
            let keys = ["省", "市", "区", "县", "镇", "街道", "路", "号", "栋", "楼", "室", "村"]
            for k in keys where s.contains(k) { return true }
            return false
        }

        // 0.9.0 的坑：只挑「第一个含快递/服务中心的字符串」，结果把「校园快递服务中心」
        // 甚至「广东省广州市…校园快递服务中心」当成驿站名，而真正该显示的是「广软多多驿站」。
        // 改成打分：含「驿站」最高，其次自提点/服务站/快递柜/超市，最后才是「服务中心」。
        static func stationScore(_ s: String) -> Int {
            guard s.count >= 2, s.count <= 24 else { return 0 }
            if looksLikeAddress(s) { return 0 }
            var score = 0
            if s.contains("驿站") { score += 5 }
            let mid = ["服务站", "自提点", "快递柜", "超市", "便利店", "门卫", "收发室", "菜鸟"]
            for k in mid where s.contains(k) { score += 3 }
            if s.contains("服务中心") { score += 1 }
            return score
        }

        static func isStation(_ s: String) -> Bool { stationScore(s) > 0 }

        static func isPlace(_ s: String) -> Bool {
            guard !s.isEmpty, s.count <= 24 else { return false }
            for k in ["货架", "货位", "取件位", "架号", "柜号"] where s.contains(k) { return true }
            return s.range(of: "^[A-Za-z]?[0-9]{1,3}-[0-9]{1,3}$", options: .regularExpression) != nil
        }

        static func items(from root: Any?) -> [PickupItem] {
            var out: [PickupItem] = []
            var seen: Set<String> = []
            walk(root, &out, &seen, 0)
            return out
        }

        private static func walk(_ node: Any?, _ out: inout [PickupItem],
                                 _ seen: inout Set<String>, _ depth: Int) {
            guard depth <= 9, let node = node else { return }

            if let dict = node as? [String: Any] {
                let vals: [String] = dict.values.compactMap { $0 as? String }
                var hit: String? = nil
                for v in vals where isCode(v) { hit = v; break }
                if let h = hit {
                    let code = PickupStore.normalize(h)
                    if !seen.contains(code) {
                        seen.insert(code)
                        var station = ""
                        var bestScore = 0
                        var place = ""
                        for v in vals {
                            if isCode(v) { continue }
                            let sc = stationScore(v)
                            if sc > bestScore { bestScore = sc; station = v }
                            if place.isEmpty && isPlace(v) { place = v }
                        }
                        let rest = vals.filter { !isCode($0) && $0 != station && $0 != place }
                        out.append(PickupItem(id: "cainiao|" + code, site: "cainiao", code: code,
                                              station: station, place: place,
                                              raw: String(rest.joined(separator: " / ").prefix(120)),
                                              seenAt: Date()))
                    }
                }
                for v in dict.values { walk(v, &out, &seen, depth + 1) }
            } else if let arr = node as? [Any] {
                for v in arr { walk(v, &out, &seen, depth + 1) }
            }
        }
    }
}
