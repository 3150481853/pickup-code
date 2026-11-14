import SwiftUI
import UIKit
import Vision

// 从截图/照片里抠取件码（系统自带 Vision，不联网、不引第三方）
enum CodeOCR {
    struct Result {
        var codes: [String] = []
        var station: String = ""
    }

    static let codePattern = "[0-9]{1,4}[ \\t]*[-－—–−][ \\t]*[0-9]{1,3}[ \\t]*[-－—–−][ \\t]*[0-9]{1,7}"

    static func scan(_ image: UIImage, completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var res = Result()
            guard let cg = cgImage(from: image) else {
                DispatchQueue.main.async { completion(res) }
                return
            }
            let lines = recognize(cg)
            var seen = Set<String>()
            for line in lines {
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
            }
            res.codes.sort()
            DispatchQueue.main.async { completion(res) }
        }
    }

    static func cgImage(from image: UIImage) -> CGImage? {
        if let cg = image.cgImage { return cg }
        if let ci = image.ciImage {
            let ctx = CIContext()
            return ctx.createCGImage(ci, from: ci.extent)
        }
        // 兜底：重画一次
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        UIGraphicsBeginImageContextWithOptions(size, false, 1)
        image.draw(in: CGRect(origin: .zero, size: size))
        let redrawn = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return redrawn?.cgImage
    }

    static func recognize(_ cg: CGImage) -> [String] {
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        // 先试中文+英文；万一这套语言组合在设备上不支持，退回默认（数字识别照样够用）
        if let lines = perform(handler, languages: ["zh-Hans", "en-US"]), !lines.isEmpty {
            return lines
        }
        return perform(handler, languages: nil) ?? []
    }

    private static func perform(_ handler: VNImageRequestHandler, languages: [String]?) -> [String]? {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        if let langs = languages { req.recognitionLanguages = langs }
        do {
            try handler.perform([req])
        } catch {
            return nil
        }
        guard let obs = req.results as? [VNRecognizedTextObservation] else { return [] }
        return obs.compactMap { $0.topCandidates(1).first?.string }
    }

    static func matches(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: codePattern, options: []) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }
    }

    // 「广软多多驿站」「校园快递服务中心」这种，掐掉前后噪声
    static func cleanStation(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for junk in ["当前", "支持退换货", "1~3天", "已入站"] where t.hasPrefix(junk) {
            t.removeFirst(junk.count)
        }
        if let r = t.range(of: "驿站") {
            var s = String(t[t.startIndex..<r.upperBound]).trimmingCharacters(in: .whitespaces)
            if s.count > 16 { s = String(s.suffix(16)) }
            return s
        }
        return t.count > 16 ? String(t.prefix(16)) : t
    }
}

// 相册/相机选图（iOS 15 没有 PhotosPicker，用 UIImagePickerController）
struct ImagePicker: UIViewControllerRepresentable {
    var source: UIImagePickerController.SourceType = .photoLibrary
    var onPick: (UIImage) -> Void

    @Environment(\.presentationMode) private var presentationMode

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.delegate = context.coordinator
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(source) ? source : .photoLibrary
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onPick(img) }
            parent.presentationMode.wrappedValue.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

// 添加取件码：手动输入 / 截图识别
struct AddItemView: View {
    @ObservedObject var store: PickupStore
    @Environment(\.presentationMode) private var presentationMode

    @State private var code = ""
    @State private var station = ""
    @State private var place = ""
    @State private var hint = ""

    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var busy = false
    @State private var found: [String] = []
    @State private var foundStation = ""
    @State private var scanned = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("手动录入")) {
                    TextField("取件码，如 54-4-13021", text: $code)
                        .keyboardType(.numbersAndPunctuation)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("驿站（可留空）", text: $station)
                    TextField("货位/货架（可留空）", text: $place)
                    Button(action: saveManual) {
                        Text("加入首页")
                    }
                    if !hint.isEmpty {
                        Text(hint).font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section(header: Text("从截图识别"), footer: Text("截图里是取件列表就行（拼多多/菜鸟/短信都行）。识别在本机做，图片不会上传。")) {
                    if busy {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在识别…").font(.footnote).foregroundColor(.secondary)
                        }
                    } else {
                        Button(action: { showLibrary = true }) {
                            Label("选相册里的截图", systemImage: "photo.on.rectangle")
                        }
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button(action: { showCamera = true }) {
                                Label("拍一张", systemImage: "camera")
                            }
                        }
                    }
                }

                if !found.isEmpty {
                    Section(header: Text("识别到 \(found.count) 个取件码"), footer: Text("点一下就能删掉不想留的")) {
                        ForEach(found, id: \.self) { c in
                            Button(action: { found.removeAll { $0 == c } }) {
                                HStack {
                                    Text(c).font(.system(.body, design: .monospaced))
                                    Spacer()
                                    Image(systemName: "minus.circle").foregroundColor(.red)
                                }
                            }
                            .foregroundColor(.primary)
                        }
                        Button(action: saveFound) {
                            Text("全部加入首页")
                        }
                    }
                } else if scanned && !busy {
                    Section {
                        Text("这张图里没认到取件码，换一张，或者手动输入。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationBarTitle("添加取件码", displayMode: .inline)
            .navigationBarItems(trailing: Button("关闭") { presentationMode.wrappedValue.dismiss() })
            .sheet(isPresented: $showLibrary) {
                ImagePicker(source: .photoLibrary) { img in runOCR(img) }
            }
            .sheet(isPresented: $showCamera) {
                ImagePicker(source: .camera) { img in runOCR(img) }
            }
        }
    }

    private func saveManual() {
        if store.addManual(code: code, station: station, place: place) {
            presentationMode.wrappedValue.dismiss()
        } else {
            hint = "这个不像取件码，格式是「数字-数字-数字」，比如 122-3-12020"
        }
    }

    private func saveFound() {
        for c in found {
            store.addManual(code: c, station: foundStation, place: "")
        }
        presentationMode.wrappedValue.dismiss()
    }

    private func runOCR(_ image: UIImage) {
        busy = true
        scanned = false
        CodeOCR.scan(image) { res in
            busy = false
            scanned = true
            found = res.codes
            foundStation = res.station
            if !res.codes.isEmpty && station.isEmpty { station = res.station }
        }
    }
}
