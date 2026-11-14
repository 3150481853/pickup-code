# 一次性补丁：给 PickupItem 加 img / mailNo，并让手动录入也能带单号
import pathlib

p = pathlib.Path(r'G:\取件码小程序\ios\PickupCode\PickupStore.swift')
s = p.read_text(encoding='utf-8')

old_struct = '''struct PickupItem: Identifiable, Hashable {
    let id: String          // 站点 + 取件码
    let site: String        // "pdd" / "taobao" / "taobao-id" / "manual"
    let code: String        // 取件码，如 47-4-11026
    let station: String     // 驿站名
    let place: String       // 货架号/取件位置
    let raw: String         // 原始文本，调试与兜底展示
    let seenAt: Date
    var img: String = ""        // 左侧主图（商品图 / 快递公司图标），没取到就是空
    var manual: Bool = false   // 手动录入 / 截图识别进来的
}'''
new_struct = '''struct PickupItem: Identifiable, Hashable {
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
}'''
assert old_struct in s, 'struct'
s = s.replace(old_struct, new_struct)

old_entry = '''    private struct ManualEntry: Codable {
        var code: String
        var station: String
        var place: String
        var seenAt: Date
    }'''
new_entry = '''    private struct ManualEntry: Codable {
        var code: String
        var station: String
        var place: String
        var seenAt: Date
        var mailNo: String? = nil
        var img: String? = nil
    }'''
assert old_entry in s, 'entry'
s = s.replace(old_entry, new_entry)

old_ingest = '''            let rawText = (r["raw"] as? String) ?? ""
            if code.isEmpty { continue }
            collected.append(PickupItem(
                id: "\\(site)|\\(code)",
                site: site,
                code: code,
                station: station,
                place: place,
                raw: rawText,
                seenAt: Date()
            ))'''
new_ingest = '''            let rawText = (r["raw"] as? String) ?? ""
            let img = (r["img"] as? String) ?? ""
            let mailNo = (r["mailNo"] as? String) ?? ""
            if code.isEmpty { continue }
            collected.append(PickupItem(
                id: "\\(site)|\\(code)",
                site: site,
                code: code,
                station: station,
                place: place,
                raw: rawText,
                seenAt: Date(),
                img: img,
                mailNo: mailNo
            ))'''
assert old_ingest in s, 'ingest'
s = s.replace(old_ingest, new_ingest)

old_add = '''    @discardableResult
    func addManual(code rawCode: String, station: String = "", place: String = "") -> Bool {
        let code = PickupStore.normalize(rawCode)
        guard PickupStore.looksLikeCode(code) else { return false }
        manualItems.removeAll { $0.code == code }
        manualItems.append(PickupItem(
            id: "manual|\\(code)",
            site: "manual",
            code: code,
            station: station.trimmingCharacters(in: .whitespacesAndNewlines),
            place: place.trimmingCharacters(in: .whitespacesAndNewlines),
            raw: "手动录入",
            seenAt: Date(),
            manual: true
        ))'''
new_add = '''    @discardableResult
    func addManual(code rawCode: String, station: String = "", place: String = "",
                   mailNo: String = "") -> Bool {
        let code = PickupStore.normalize(rawCode)
        guard PickupStore.looksLikeCode(code) else { return false }
        let no = mailNo.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        manualItems.removeAll { $0.code == code }
        manualItems.append(PickupItem(
            id: "manual|\\(code)",
            site: "manual",
            code: code,
            station: station.trimmingCharacters(in: .whitespacesAndNewlines),
            place: place.trimmingCharacters(in: .whitespacesAndNewlines),
            raw: "手动录入",
            seenAt: Date(),
            mailNo: no,
            manual: true
        ))'''
assert old_add in s, 'addManual'
s = s.replace(old_add, new_add)

old_save = '''        let rows = manualItems.map { ManualEntry(code: $0.code, station: $0.station, place: $0.place, seenAt: $0.seenAt) }'''
new_save = '''        let rows = manualItems.map { ManualEntry(code: $0.code, station: $0.station, place: $0.place,
                                                 seenAt: $0.seenAt, mailNo: $0.mailNo, img: $0.img) }'''
assert old_save in s, 'saveManual'
s = s.replace(old_save, new_save)

old_load = '''            PickupItem(id: "manual|\\($0.code)", site: "manual", code: $0.code,
                       station: $0.station, place: $0.place, raw: "手动录入",
                       seenAt: $0.seenAt, manual: true)'''
new_load = '''            PickupItem(id: "manual|\\($0.code)", site: "manual", code: $0.code,
                       station: $0.station, place: $0.place, raw: "手动录入",
                       seenAt: $0.seenAt, img: $0.img ?? "", mailNo: $0.mailNo ?? "",
                       manual: true)'''
assert old_load in s, 'loadManual'
s = s.replace(old_load, new_load)

old_merge = '''                if var had = byCode[it.code] {
                    if had.station.isEmpty && !it.station.isEmpty { had = PickupItem(id: had.id, site: had.site, code: had.code, station: it.station, place: had.place, raw: had.raw, seenAt: had.seenAt, manual: had.manual) }
                    if had.place.isEmpty && !it.place.isEmpty { had = PickupItem(id: had.id, site: had.site, code: had.code, station: had.station, place: it.place, raw: had.raw, seenAt: had.seenAt, manual: had.manual) }
                    byCode[it.code] = had
                } else {'''
new_merge = '''                if var had = byCode[it.code] {
                    // 手动的优先，缺的字段用抓到的补
                    if had.station.isEmpty { had.station = it.station }
                    if had.place.isEmpty { had.place = it.place }
                    if had.img.isEmpty { had.img = it.img }
                    if had.mailNo.isEmpty { had.mailNo = it.mailNo }
                    if had.raw.isEmpty { had.raw = it.raw }
                    byCode[it.code] = had
                } else {'''
assert old_merge in s, 'merge'
s = s.replace(old_merge, new_merge)

p.write_text(s, encoding='utf-8')
print('OK PickupStore.swift', len(s))
