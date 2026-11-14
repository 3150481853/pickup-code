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

        /// 商品主图：接口里的图基本都在 alicdn 上，认 http(s) + 图片后缀/常见图床
        static func imgOf(_ cand: [String]) -> String {
            var fallback = ""
            for s in cand {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.hasPrefix("http"), t.count > 18, t.count < 500 else { continue }
                let low = t.lowercased()
                if low.hasSuffix(".jpg") || low.hasSuffix(".jpeg") || low.hasSuffix(".png")
                    || low.hasSuffix(".webp") || low.contains("alicdn.com/img")
                    || low.contains("img.alicdn") || low.contains("gw.alicdn") {
                    return t
                }
                if fallback.isEmpty { fallback = t }
            }
            return fallback
        }

        /// 快递单号：YT7656364590990 / JT3184428901216，或 12~18 位纯数字（丹鸟/韵达那种）
        static let mailPattern = "(?<![A-Za-z0-9])(?:[A-Z]{2,3}[0-9]{8,14}|[0-9]{12,18})(?![0-9])"

        static func mailNoOf(_ cand: [String]) -> String {
            var loose = ""
            for s in cand {
                let t = s.uppercased()
                let ns = t as NSString
                guard let re = try? NSRegularExpression(pattern: mailPattern) else { return loose }
                for m in re.matches(in: t, options: [], range: NSRange(location: 0, length: ns.length)) {
                    let no = ns.substring(with: m.range)
                    // 11 位纯数字基本都是手机号，跳过
                    if no.count == 11 && no.allSatisfy({ $0.isNumber }) { continue }
                    if no.range(of: "^[A-Z]{2,3}[0-9]+$", options: .regularExpression) != nil { return no }
                    if loose.isEmpty { loose = no }
                }
            }
            return loose
        }

        static func items(from root: Any?) -> [PickupItem] {
            var out: [PickupItem] = []
            var seen: Set<String> = []
            walk(root, &out, &seen, 0)
            return out
        }

        private static func walk(_ node: Any?, _ out: inout [PickupItem],
                                 _ seen: inout Set<String>, _ depth: Int) {
            guard depth <= 10, let node = node else { return }

            if let dict = node as? [String: Any] {
                if let hit = codeOf(dict) {
                    if !seen.contains(hit) {
                        seen.insert(hit)
                        // 驿站名常常藏在 feature / feature2 里那层转义过的 JSON（postName / daishouName）
                        let cand = collect(dict)
                        var station = ""
                        var bestScore = 0
                        var place = ""
                        for v in cand {
                            if isCode(v) { continue }
                            let sc = stationScore(v)
                            if sc > bestScore { bestScore = sc; station = v }
                            if place.isEmpty && isPlace(v) { place = v }
                        }
                        let rest = cand.filter { !isCode($0) && $0 != station && $0 != place }
                        out.append(PickupItem(id: "cainiao|" + hit, site: "cainiao", code: hit,
                                              station: station, place: place,
                                              raw: String(rest.joined(separator: " / ").prefix(120)),
                                              seenAt: Date(),
                                              img: imgOf(cand),
                                              mailNo: mailNoOf(cand)))
                    }
                }
                for v in dict.values {
                    if let s = v as? String { walkString(s, &out, &seen, depth + 1) }
                    else { walk(v, &out, &seen, depth + 1) }
                }
            } else if let arr = node as? [Any] {
                for v in arr { walk(v, &out, &seen, depth + 1) }
            }
        }

        /// 字符串值本身可能是一层转义 JSON（feature2 就是），解开继续找
        private static func walkString(_ s: String, _ out: inout [PickupItem],
                                      _ seen: inout Set<String>, _ depth: Int) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2 else { return }
            guard (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("[") && t.hasSuffix("]")) else { return }
            guard let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return }
            walk(obj, &out, &seen, depth + 1)
        }

        /// 字段名带 code / pick 的先看，其次任意字符串
        private static func codeOf(_ dict: [String: Any]) -> String? {
            var loose: String? = nil
            for (k, v) in dict {
                guard let s = v as? String, isCode(s) else { continue }
                let n = PickupStore.normalize(s)
                let lk = k.lowercased()
                if lk.contains("code") || lk.contains("pick") { return n }
                if loose == nil { loose = n }
            }
            return loose
        }

        /// 把这一层 + 里面转义 JSON 里的字符串都收集起来，用来挑驿站名/货位
        private static func collect(_ dict: [String: Any], _ depth: Int = 0) -> [String] {
            guard depth <= 2 else { return [] }
            var out: [String] = []
            for (_, v) in dict {
                guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                if s.hasPrefix("{"), s.hasSuffix("}"),
                   let data = s.data(using: .utf8),
                   let inner = try? JSONSerialization.jsonObject(with: data, options: []),
                   let d = inner as? [String: Any] {
                    out.append(contentsOf: collect(d, depth + 1))
                    continue
                }
                out.append(s)
            }
            return out
        }
    }
}
