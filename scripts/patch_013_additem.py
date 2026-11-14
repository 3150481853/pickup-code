# 给 AddItem.swift 加「快递单号」输入与识别
import pathlib

p = pathlib.Path(r'G:\取件码小程序\ios\PickupCode\AddItem.swift')
s = p.read_text(encoding='utf-8')

old_res = '''    struct Result {
        var codes: [String] = []
        var station: String = ""
    }'''
new_res = '''    struct Result {
        var codes: [String] = []
        var station: String = ""
        var mailNos: [String] = []   // 截图里认到的快递单号（YT7656364590990 / 611723856155233 这种）
    }'''
assert old_res in s, 'Result'
s = s.replace(old_res, new_res)

old_pat = r'''    static let codePattern = "(?:[A-Za-z]{1,3}[ \\t]*[-－—–−﹣‑][ \\t]*[0-9]{1,7}|[0-9]{1,4}[ \\t]*[-－—–−][ \\t]*[0-9]{1,7}(?:[ \\t]*[-－—–−][ \\t]*[0-9]{1,7})?)"'''
new_pat = r'''    static let codePattern = "(?:[A-Za-z]{1,3}[ \\t]*[-－—–−﹣‑][ \\t]*[0-9]{1,7}|[0-9]{1,4}[ \\t]*[-－—–−][ \\t]*[0-9]{1,7}(?:[ \\t]*[-－—–−][ \\t]*[0-9]{1,7})?)"
    /// 快递单号：字母前缀 + 8~14 位数字（圆通 YT…、极兔 JT…、顺丰 SF…），或者纯数字 12~18 位（丹鸟/韵达那种）
    static let mailPattern = "(?<![A-Za-z0-9])(?:[A-Za-z]{2,3}[0-9]{8,14}|[0-9]{12,18})(?![0-9])"'''
assert old_pat in s, 'codePattern'
s = s.replace(old_pat, new_pat)

old_loop = '''            for line in lines {
                for raw in matches(in: line) {
                    let code = PickupStore.normalize(raw)
                    if PickupStore.looksLikeCode(code), !seen.contains(code) {
                        seen.insert(code)
                        res.codes.append(code)
                    }
                }
                if res.station.isEmpty, line.contains("驿站") || line.contains("服务中心") {
                    res.station = cleanStation(line)
                }
            }'''
new_loop = '''            var seenNo = Set<String>()
            for line in lines {
                for raw in matches(in: line) {
                    let code = PickupStore.normalize(raw)
                    if PickupStore.looksLikeCode(code), !seen.contains(code) {
                        seen.insert(code)
                        res.codes.append(code)
                    }
                }
                for raw in mailMatches(in: line) {
                    let no = raw.uppercased().replacingOccurrences(of: " ", with: "")
                    if !seenNo.contains(no) {
                        seenNo.insert(no)
                        res.mailNos.append(no)
                    }
                }
                if res.station.isEmpty, line.contains("驿站") || line.contains("服务中心") {
                    res.station = cleanStation(line)
                }
            }'''
assert old_loop in s, 'loop'
s = s.replace(old_loop, new_loop)

old_matches = '''    static func matches(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: codePattern, options: []) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }'''
new_matches = '''    static func matches(in text: String) -> [String] {
        regexHits(text, codePattern)
    }

    static func mailMatches(in text: String) -> [String] {
        // 11 位纯数字当手机号排掉，不然快递单号里全是电话号码
        regexHits(text, mailPattern).filter { !($0.count == 11 && $0.allSatisfy { $0.isNumber }) }
    }

    static func regexHits(_ text: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }'''
assert old_matches in s, 'matches'
s = s.replace(old_matches, new_matches)

# UI: 单号输入框
old_ui = '''    @State private var code = ""
    @State private var station = ""
    @State private var place = ""
    @State private var hint = ""'''
new_ui = '''    @State private var code = ""
    @State private var station = ""
    @State private var place = ""
    @State private var mailNo = ""
    @State private var hint = ""'''
assert old_ui in s, 'ui state'
s = s.replace(old_ui, new_ui)

old_form = '''                    TextField("驿站（可留空）", text: $station)
                    TextField("货位/货架（可留空）", text: $place)'''
new_form = '''                    TextField("快递单号（可留空，如 YT7656364590990）", text: $mailNo)
                        .keyboardType(.asciiCapable)
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                    TextField("驿站（可留空）", text: $station)
                    TextField("货位/货架（可留空）", text: $place)'''
assert old_form in s, 'form'
s = s.replace(old_form, new_form)

old_scan = '''            found = res.codes
            foundStation = res.station
            if !res.codes.isEmpty && station.isEmpty { station = res.station }'''
new_scan = '''            found = res.codes
            foundStation = res.station
            if !res.codes.isEmpty && station.isEmpty { station = res.station }
            // 单号只有一个、码也只有一个时才自动填，免得对错行
            if mailNo.isEmpty, res.mailNos.count == 1, res.codes.count == 1 {
                mailNo = res.mailNos[0]
            }'''
assert old_scan in s, 'scan'
s = s.replace(old_scan, new_scan)

old_save = '''    private func saveManual() {
        if store.addManual(code: code, station: station, place: place) {'''
new_save = '''    private func saveManual() {
        if store.addManual(code: code, station: station, place: place, mailNo: mailNo) {'''
assert old_save in s, 'saveManual'
s = s.replace(old_save, new_save)

old_found = '''        for c in found {
            store.addManual(code: c, station: foundStation, place: "")
        }'''
new_found = '''        for c in found {
            store.addManual(code: c, station: foundStation, place: "",
                            mailNo: found.count == 1 ? mailNo : "")
        }'''
assert old_found in s, 'saveFound'
s = s.replace(old_found, new_found)

p.write_text(s, encoding='utf-8')
print('OK AddItem.swift', len(s))
