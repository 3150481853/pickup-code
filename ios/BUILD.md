# 打「未签名 ipa」

## 先说清楚一件事

**这台 Windows 电脑打不出 ipa。** 不是流程问题，是工具链问题：

iOS 的可执行文件是 arm64 Mach-O，必须用 Apple 的 iOS SDK（UIKit / WebKit 头文件和 .tbd 存根）链接，而 iOS SDK 只随 Xcode 发布、只能在 macOS 上跑。

本机实测：

| 东西 | 结果 |
| --- | --- |
| `clang` / `clang++` / `swift` / `swiftc` | MISSING |
| iOS SDK | 不存在 |
| WSL | 只有 `wsl.exe`，没装任何发行版 |
| git | `C:\Program Files\Git\cmd\git.exe` ✅ |
| `ld` | `C:\mingw64\bin\ld.exe`（MinGW 的 PE 链接器，对 iOS 无用） |

所以「在这台电脑上编译」这条路是死路。能做的只有**云编译**：工程和流水线我已经写好了，你只需要把仓库推上去，GitHub 的 macOS runner 替你编译，产出未签名 ipa，你下载后用全能签签。

## 目录

```
.github/workflows/ios-unsigned.yml     # 云编译流水线（macos-14 + Xcode 15）
ios/project.yml                        # XcodeGen 工程描述
ios/PickupCode/Info.plist
ios/PickupCode/PickupCodeApp.swift     # SwiftUI 界面：三个标签 + 底栏
ios/PickupCode/Sites.swift             # 站点表 + 导航白名单 + WebBox（WKWebView 封装）
ios/PickupCode/Resources/inject-pdd.js     # 拼多多：同源改路 + 去广告 + 大图
ios/PickupCode/Resources/inject-taobao.js  # 淘宝/菜鸟：去掉「需要登录」横条、修 iframe 顶偏
```

壳做的事：

1. `WKUserScript(injectionTime: .atDocumentStart, forMainFrameOnly: false)` 在页面脚本之前分别注入三个站点的脚本；
2. `WKWebsiteDataStore.default()` 让登录态落盘，重启 App 不用重新登录；三个 WebView 常驻，切标签只是移动视图、不重载（不丢 H5 状态）；
3. 导航限制：每个标签只允许自己那份域名白名单在主 WebView 里开，站外 http(s) 扔给 Safari，`pinduoduo://` 之类自定义 scheme 交给系统；
4. 右上角两个小胶囊：刷新 / 回入口（回入口用的是官方 entry，跳转没方向时点它）。

## 三个标签（聚合的来源）

| 标签 | 入口 | 关键点 |
| --- | --- | --- |
| 拼多多 | `m.pinduoduo.net/mdkd/package?tab=ID_CODE` | 脚本把 `api.pinduoduo.com/api/` 改写成 `m.pinduoduo.net/proxy/api/api/`，否则登录态过不了 |
| 淘宝取件 | `pages-fast.m.taobao.com/wow/z/uniapp/1011717/last-mile-fe/end-collect-platform/identity-code` | 官方「驿站代收」页，身份码 + 待取包裹；未登录时藏掉「您需要登录才能继续访问」横条 |
| 菜鸟码 | `page.cainiao.com/cn-app-web/identity-code/index.html#/` | 官方身份码页，用淘宝登录态，和淘宝标签共用会话 |

淘宝和菜鸟互相同步会话，所以**只在淘宝标签登录一次**即可；拼多多需要单独登录（可以用小号登录网页端，再在「待取包裹」里验证大号收件手机号，避免顶掉你手机上的拼多多 App 会话）。


## 已跑通（2026-11-14）

推上 GitHub 后第一次就编过了，Swift 代码没报错。产物两份（两个镜像各跑一次，取任一份都行）：

- run：`https://github.com/3150481853/pickup-code/actions/runs/43543284981`
- artifact：`PickupCode-unsigned-ipa-macos-15` / `PickupCode-unsigned-ipa-macos-latest`
- 本体：56 KB，`Payload/PickupCode.app/PickupCode` 是 `cf fa ed fe 0c 00 00 01`（arm64 Mach-O），`Info.plist` 编译后为 bplist，`DTPlatformName=iphoneos`、SDK `iphoneos18.5`、`MinimumOSVersion=15.0`、`UIDeviceFamily=1`
- 仓库里 `dist/PickupCode-unsigned.ipa` 是我下载下来的一份，可直接拿去签

**踩到的坑**：`runs-on: macos-14` 在这个账号上被解析成 `macos-14-arm64-us-default`，job 起跑 1 秒就被 cancel，Annotations 里写 `The configuration 'macos-14-arm64-us-default' is not supported`，0 个 step 执行。解决：`matrix.os: [macos-15, macos-latest]` + `fail-fast: false`，macos-13 排队太久就别要了。

## 你这边三步

1. 在 GitHub 新建一个**空**仓库（private 也行，Actions 免费额度够这个项目跑几千次）。
2. 在这个目录里：

```powershell
cd G:\取件码小程序
git init
git add .
git commit -m "pickup code webview shell"
git branch -M main
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

3. 打开仓库 → Actions → `build-unsigned-ipa` → 等 3~5 分钟 → 进这次运行页面底部 **Artifacts** 下载 `PickupCode-unsigned-ipa.zip`，解压得到 `PickupCode-unsigned.ipa`。

然后丢进全能签签名安装。Bundle ID 是 `local.pickup.code`，要改就改 `ios/project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER`。

## 没有 GitHub 账号的替代

- **Codemagic** / **AppCircle**：都有免费层，支持直接上传源码 zip 在云端 macOS 构建，同样能出未签名 ipa。
- 但不管哪家，**都需要一个账号 + 一次联网构建**，Windows 本地无法绕过。

## 首次构建可能踩的坑

工程是我手写的，本机没法编译验证，所以第一次跑很可能需要在 CI 上迭代。常见问题：

| 现象 | 改法 |
| --- | --- |
| `scheme PickupCode not found` | 确认 `ios/project.yml` 的 `schemes:` 段没被改动 |
| `No signing certificate` | 确认三个 `CODE_SIGNING_*` 参数都传了（流水线里已带） |
| ipa 装上后白屏 | `Resources/*.js` 没打进包：检查 `ios/PickupCode/Resources/` 下两个 js 是否被 XcodeGen 当成 resource 拷进 `.app`（`unzip -l` 能看到） |
| 登录后仍弹回登录页 | 注入没生效（同上），或脚本的 mapping 需要按新版接口调整 |
| 淘宝标签一片空白、只有一条横条 | 淘宝登录 iframe 在 WKWebView 里被判成三方 Cookie。临时办法：先在 Safari 里登录一次淘宝，或把 `inject-taobao.js` 里的 `liftFrames()` 关掉，看是不是我们自己把 iframe 顶没了 |
| 编译报 Swift 错误 | 把 Actions 日志贴给我，我直接改 |

## 提醒

自签 App 的可用期取决于你用哪张证书（个人证书 7 天 / 付费开发者 1 年 / 企业证书看脸），到期要重签。这是签名侧的事，你说你自己搞，我就不掺和了。
