# 取件码小程序 · 拼多多取件极简方案（iOS）

目标：在学校驿站不再「打开拼多多 → 扫码 → 找身份码 → 被广告糊一脸」。

---

## 一、先说结论

| 方案 | 能不能做 | 代价 |
| --- | --- | --- |
| **微信小程序** | ❌ 做不了 | 见下面「为什么小程序不行」 |
| **A. 快捷指令直跳 App 身份码** | ✅ 30 秒能验 | 还是在拼多多 App 里，但跳过首页和扫码 |
| **B. Safari + 脚本（本仓库脚本）** | ✅ 免签名 | 要装一个 Safari 扩展，网页登录会和 App 互踢 |
| **C. 自签 ipa（原生 App）** | ✅ 体验最好 | 要签名、7 天续签（SideStore 可自动） |

---

## 二、为什么微信小程序不行

不是「麻烦」，是三条硬限制，绕不过去：

1. 小程序的 `<web-view>` 只能加载**你自己在公众平台配置过的「业务域名」**，而且要在该域名根目录放校验文件。`m.pinduoduo.net` 不是我们的域名，永远配不进去。
2. 小程序**不允许注入脚本**改页面，所以连「打开官方网页再整理一下」这条 HandyCode 的路都走不了。
3. 拼多多没有开放的取件码 / 身份码接口。

结论：小程序可以做成「手动粘贴一串码然后大字显示」，但那就没有意义了。

---

## 三、实测到的技术事实（这是能做的原因）

我在桌面浏览器上打开官方入口 `https://m.pinduoduo.net/mdkd/package?tab=ID_CODE`，抓到这些请求：

```
POST https://api.pinduoduo.com/api/express_trackbox/station/package      → 424
POST https://api.pinduoduo.com/api/apoc/binding/mobile/.../pre/check     → 424
GET  https://m.pinduoduo.net/login.html?from=https%3A%2F%2Fm.pinduoduo.net%2Fmdkd%2Fpackage%3Ftab%3DID_CODE  → 200
GET  https://m.pinduoduo.net/proxy/api/api/galen/grayscale?...           → 200
GET  https://m.pinduoduo.net/proxy/api/api/server/_stm?...               → 200
```

也就是说：

- 身份码页的业务请求发往 **`api.pinduoduo.com`**（跨站），浏览器不带 Cookie + 跨站策略 → **424**，然后被弹回登录页；
- 拼多多自己的**同源官方路由** `m.pinduoduo.net/proxy/api/...` 是正常 200 的。

所以纯浏览器打开这个页面，**登录完还会一直弹回登录页**。HandyCode 做的核心就是这个改写：

```
https://api.pinduoduo.com/api/express_trackbox/...
            ↓
https://m.pinduoduo.net/proxy/api/api/express_trackbox/...
```

（注意 `/proxy/api/api/` 两个 `api` 是故意的：官方代理前缀是 `/proxy/api`，原路径仍以 `/api/` 开头。）

`pdd-pickup.user.js` 就是把这套逻辑搬到浏览器里，**只改地址，不碰 Cookie、不碰请求头、不代发请求**。

---

## 四、方案 A：快捷指令直跳（先试这个，30 秒）

拼多多 App 支持直达身份码页的 deep link：

```
pinduoduo://com.xunmeng.pinduoduo/mdkd/package?tab=ID_CODE
```

步骤：

1. 先在 **Safari 地址栏**里粘这行，回车，看会不会直接跳进拼多多 App 的身份码页。
2. 能跳的话，打开「快捷指令」App → 新建 → 添加操作「URL」填上面这串 → 再加「打开 URL」→ 命名为「取件码」。
3. 快捷指令详情里「添加到主屏幕」，选个图标。之后：**桌面点一下 → 直接身份码页**。
4. 还能加「轻点背面两下」：设置 → 辅助功能 → 触控 → 轻点背面 → 双击 → 选这个快捷指令。

缺点：仍是 App 内页面，底部 tab 和 App 自己的东西还在。优点：零成本，今天就能用。

---

## 五、方案 B：Safari + 脚本（免签名，去广告）

### 装

1. App Store 搜 **Userscripts**（免费开源，Safari 扩展）装好。
2. 设置 → Safari → 扩展 → 打开 Userscripts，允许访问 `m.pinduoduo.net`。
3. 打开 Userscripts App，把 `pdd-pickup.user.js` 放进去（App 里「打开文件夹」后用「文件」App 拷进去；或者用它的在线导入贴代码）。
4. Safari 里打开：
   `https://m.pinduoduo.net/mdkd/package?tab=ID_CODE`
   点「手机登录」，收验证码登录一次。

### 验

登录成功后，页面应该**不再弹回登录页**，能看到身份码 + 待取包裹。

- 如果还是弹回登录页 → 脚本没注入，检查扩展是否对该站点启用。
- 右下角会有一个半透明的「简」按钮：
  - 点一下 = 精简模式（把推荐、百亿补贴、猜你喜欢这类整块藏掉）
  - 长按 = 圈选模式，再长按页面上任意一块就把它藏起来（存在 localStorage，下次自动生效）
  - 身份码图片点一下 = 横过来放大，点一下关掉

### 在手机上做「一键入口」

「添加到主屏幕」的网页 App 是独立 WebView，**Safari 扩展在里面通常不生效**（要实测；不生效就会弹回登录页）。所以入口用快捷指令更稳：

快捷指令 = 「打开 URL：`https://m.pinduoduo.net/mdkd/package?tab=ID_CODE`」→ 添加到主屏幕。

### 已知代价（诚实说）

- **网页登录和 App 登录会互踢**：同一账号在网页端登录，可能把 App 的会话顶掉。HandyCode 作者的建议是：网页端用小号登录，然后在「待取包裹」里添加**大号的收件手机号**并验证，包裹照样能看。
- 登录态靠 Safari 的 Cookie。清缓存、`设置 → Safari → 清除历史记录`、服务端会话过期、风控要求重新验证，都要重新登录一次。

---

## 六、方案 C：自签 ipa（体验最接近 HandyCode）

工程已经写好了（`ios/` 目录）：SwiftUI + WKWebView 壳，三个常驻标签页，每个页面各自注入脚本。

- 打开即身份码，无地址栏
- 桌面图标直达
- 登录态用 `WKWebsiteDataStore.default()` 落盘，切页只移动视图、不重载
- 站外链接扔给 Safari，自定义 scheme（`pinduoduo://`）交给系统

### 聚合三个平台（这是解决「菜鸟看不到圆通件」的关键）

| 标签 | 官方入口 | 能看到什么 |
| --- | --- | --- |
| 拼多多 | `m.pinduoduo.net/mdkd/package?tab=ID_CODE` | 身份码 + 待取包裹（淘宝/天猫里被拼多多代收的件，主要是圆通） |
| 淘宝取件 | `pages-fast.m.taobao.com/wow/z/uniapp/1011717/last-mile-fe/end-collect-platform/identity-code` | 身份码 + 待取包裹（菜鸟那一侧的取件码） |
| 菜鸟码 | `page.cainiao.com/cn-app-web/identity-code/index.html#/` | 菜鸟官方身份码（登录态与淘宝共用） |

三个都是**官方网页**，App 不解析、不缓存、不上传你的码。淘宝和菜鸟共用淘宝登录态，拼多多单独登录。

**但是：这台 Windows 电脑编不出 ipa。** iOS 二进制必须用 Apple 的 iOS SDK（只在 macOS 上）链接，本机 `clang`/`swift`/iOS SDK 全都没有，WSL 也没装发行版。所以只能云编译：

- 流水线我写好了：`.github/workflows/ios-unsigned.yml`（macos-14 + XcodeGen + `CODE_SIGNING_ALLOWED=NO`）
- 你推上 GitHub → Actions 跑一次 → 下载 **未签名 ipa** → 全能签签名安装

详细步骤在 [ios/BUILD.md](ios/BUILD.md)。

---

## 七、文件

- `pdd-pickup.user.js` —— 脚本本体，方案 B 直接装；方案 C 复用同一段逻辑
- `_syntax-check.html` —— 用来在浏览器里自检脚本能不能正常加载（打开它应该显示 `SCRIPT LOADED OK`）

## 八、风险声明

非官方的个人使用工具，依赖拼多多官方网页，平台改版就会失效。请以学校驿站实际要求为准。
