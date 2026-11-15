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
        /// 诊断用：从 raw JSON 里挑出像图片的地址 —— 主图取不到时，得先知道返回里到底有没有图
        static func imageCandidates(_ raw: String, limit: Int = 6) -> [String] {
            let flat = raw.replacingOccurrences(of: "\\/", with: "/")
            guard let re = try? NSRegularExpression(pattern: "https?://[^\"'\\s\\\\]{18,300}") else { return [] }
            let ns = flat as NSString
            var out: [String] = []
            for m in re.matches(in: flat, options: [], range: NSRange(location: 0, length: ns.length)) {
                let u = ns.substring(with: m.range).lowercased()
                let looks = u.contains(".jpg") || u.contains(".jpeg") || u.contains(".png")
                    || u.contains(".webp") || u.contains("alicdn") || u.contains("pddpic")
                    || u.contains("hdslb")
                if looks, !out.contains(where: { $0.hasPrefix(String(u.prefix(40))) }) { out.append(u) }
                if out.count >= limit { break }
            }
            return out
        }

        static func isCode(_ s: String) -> Bool {            let t = PickupStore.normalize(s)
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

        /// JSON 里的噪声：布尔、小数（经纬度）、长数字 ID、空串 —— 这些绝不能当货位/驿站/单号
        static func isJunk(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.count > 60 { return true }
            let low = t.lowercased()
            if low == "true" || low == "false" || low == "null" || low == "none" { return true }
            if t.contains(".") { return true }                       // 23.451012 这种
            if t.count >= 6 && t.allSatisfy({ $0.isNumber }) { return true }   // 440184 / 4401841…
            if t.range(of: "0{5,}", options: .regularExpression) != nil { return true }  // 50000000000049
            return false
        }

        static func isPlace(_ s: String) -> Bool {
            guard !s.isEmpty, s.count <= 12, !isJunk(s) else { return false }
            for k in ["货架", "货位", "取件位", "架号", "柜号"] where s.contains(k) { return true }
            // 4-11 / A2-3 这种货位号；不能是取件码本身（三段）
            return s.range(of: "^[A-Za-z]?[0-9]{1,3}-[0-9]{1,3}$", options: .regularExpression) != nil
        }

        /// 快递单号：YT7656364590990 / JT3184428901216，或 12~18 位纯数字（丹鸟/韵达那种）
        static let mailPattern = "(?<![A-Za-z0-9])(?:[A-Z]{2,3}[0-9]{8,14}|[0-9]{12,18})(?![0-9])"

        static func mailNoOf(_ cand: [String]) -> String {
            var loose = ""
            for s in cand {
                let t = s.uppercased()
                if isJunk(t) { continue }
                let ns = t as NSString
                guard let re = try? NSRegularExpression(pattern: mailPattern) else { return loose }
                for m in re.matches(in: t, options: [], range: NSRange(location: 0, length: ns.length)) {
                    let no = ns.substring(with: m.range)
                    // 11 位纯数字基本都是手机号，跳过
                    if no.count == 11 && no.allSatisfy({ $0.isNumber }) { continue }
                    // 长串 0 的伪 ID（50000000000049）跳过
                    if no.range(of: "0{5,}", options: .regularExpression) != nil { continue }
                    if no.range(of: "^[A-Z]{2,3}[0-9]+$", options: .regularExpression) != nil { return no }
                    if loose.isEmpty { loose = no }
                }
            }
            return loose
        }

        /// 商品主图：宁可没有图（用站点图标兜底），也不要放错图。
        /// 之前按「第一个 http 串」取，结果取到了快递 logo / 广告图 / 埋点像素，看着就是「图不对」。
        static func imgOf(_ pairs: [(String, String)]) -> String {
            var best = ""
            var bestScore = 0
            var fallback = ""
            var fbScore = 0
            for (key, value) in pairs {
                let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.hasPrefix("http"), t.count > 18, t.count < 600 else { continue }
                let low = t.lowercased()
                let lk = key.lowercased()
                // 埋点像素、占位图、动图一律不要
                if low.contains("1x1") || low.contains("track") || low.contains("placeholder")
                    || low.contains("loading") || low.hasSuffix(".gif") { continue }
                let isProductish = lk.contains("img") || lk.contains("pic") || lk.contains("photo")
                    || lk.contains("image") || lk.contains("url")
                // 第一档：商品图
                var score = 0
                if isProductish { score += 4 }
                if low.contains("/bao/uploaded/") || low.contains("imgextra") { score += 4 }
                if low.contains("alicdn.com/img") || low.contains("img.alicdn") { score += 3 }
                else if low.contains("alicdn.com") || low.contains("taobaocdn") { score += 2 }
                if low.hasSuffix(".jpg") || low.hasSuffix(".jpeg")
                    || low.hasSuffix(".png") || low.hasSuffix(".webp") { score += 2 }
                if low.range(of: "_[4-9][0-9]{2}x[4-9][0-9]{2}",
                             options: .regularExpression) != nil { score += 1 }
                if score > bestScore { bestScore = score; best = t }

                // 第二档（兜底）：没有商品图时用快递公司 logo —— 总比空着强，
                // 之前一律排掉 logo，结果整列都是图标。
                var fb = 0
                if lk.contains("logo") || lk.contains("icon") || lk.contains("brand")
                    || lk.contains("company") || lk.contains("express") { fb += 3 }
                if low.hasSuffix(".jpg") || low.hasSuffix(".jpeg")
                    || low.hasSuffix(".png") || low.hasSuffix(".webp") { fb += 2 }
                else if low.contains("alicdn") || low.contains("pddpic") || low.contains("hdslb") { fb += 1 }
                if fb > fbScore { fbScore = fb; fallback = t }
            }
            if bestScore >= 3 { return best }
            return fallback
        }

        /// 收集 (字段名, 值)：既钻进 feature / feature2 那层转义 JSON，也钻进普通的嵌套对象/数组，
        /// 保留内层字段名（图片常挂在 `{"image":{"url": ...}}` 这种嵌套里）
        private static func pairs(_ dict: [String: Any], _ depth: Int = 0) -> [(String, String)] {
            guard depth <= 3 else { return [] }
            var out: [(String, String)] = []
            for (k, v) in dict {
                if let d = v as? [String: Any] {
                    out.append(contentsOf: pairs(d, depth + 1))
                    continue
                }
                if let a = v as? [Any] {
                    for e in a {
                        if let d = e as? [String: Any] { out.append(contentsOf: pairs(d, depth + 1)) }
                        else if let s = (e as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                            out.append((k, s))
                        }
                    }
                    continue
                }
                guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                if (s.hasPrefix("{") || s.hasPrefix("[")) && s.count >= 2,
                   let data = s.data(using: .utf8),
                   let inner = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                    if let d = inner as? [String: Any] {
                        out.append(contentsOf: pairs(d, depth + 1))
                        continue
                    }
                    if let a = inner as? [Any] {
                        for e in a where (e as? [String: Any]) != nil {
                            out.append(contentsOf: pairs(e as! [String: Any], depth + 1))
                        }
                        continue
                    }
                }
                out.append((k, s))
            }
            return out
        }

        /// 「已经拿走/已签收」的记录：菜鸟接口按 30 天返回，不筛会把取过的也列出来
        private static let doneWords = ["已取件", "已取走", "已领取", "已领", "已妥投", "已完成",
                                        "已取消", "已退回", "已签收", "交易关闭", "已过期"]
        private static let pendingWords = ["待取", "未取", "待领取", "待自提", "已入库", "已到站", "待签收"]

        static func isDone(_ vals: [String]) -> Bool {
            let text = vals.joined(separator: " ")
            if pendingWords.contains(where: { text.contains($0) }) { return false }
            return doneWords.contains(where: { text.contains($0) })
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
                    let ps = pairs(dict)
                    // 噪声（true/false、经纬度、长 ID）先剔掉，否则驿站/货位/单号都会挑到垃圾值
                    let cand = ps.map { $0.1 }.filter { !isJunk($0) }
                    // 已经取走/签收的也会被这个接口按「近 30 天」返回，这里筛掉
                    if !seen.contains(hit) && !isDone(cand) {
                        seen.insert(hit)
                        var station = ""
                        var bestScore = 0
                        var place = ""
                        for v in cand {
                            if isCode(v) { continue }
                            let sc = stationScore(v)
                            if sc > bestScore { bestScore = sc; station = v }
                            if place.isEmpty && isPlace(v) { place = v }
                        }
                        let rest = cand.filter { !isCode($0) && !isJunk($0) && $0 != station && $0 != place }
                        out.append(PickupItem(id: "cainiao|" + hit, site: "cainiao", code: hit,
                                              station: station, place: place,
                                              raw: String(rest.joined(separator: " / ").prefix(120)),
                                              seenAt: Date(),
                                              img: imgOf(ps),
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
