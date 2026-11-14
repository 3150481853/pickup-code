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
            return PickupStore.looksLikeCode(t)
        }

        static func isStation(_ s: String) -> Bool {
            guard s.count >= 2, s.count <= 30 else { return false }
            let keys = ["驿站", "快递", "超市", "服务中心", "自提点", "便利店", "菜鸟", "门卫", "收发室", "柜"]
            for k in keys where s.contains(k) { return true }
            return false
        }

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
                        var place = ""
                        for v in vals {
                            if isCode(v) { continue }
                            if station.isEmpty && isStation(v) { station = v }
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
