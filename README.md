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

## 六、方案 C：自签 ipa（已跑通，出过可安装的包）

工程在 `ios/`：SwiftUI + WKWebView 壳，**四个底栏**，页面常驻不重载。

### 首页 = 所有待取件汇总

打开 App 第一屏就是汇总列表：每行一个取件码（大号等宽字体）+ 来源标签 + 驿站/货位，**点一下就复制**。顶上「刷新全部」把三个站点的页面重新拉一遍。空列表时会显示每个站点的状态（如「未登录 / 登录中」「抓到 7 件」），方便判断该去哪个标签登录。

抓取靠注入的 `ios/PickupCode/Resources/pickup-agent.js`：拼多多读官方 DOM（`[class*="package-list-picking"]` 里的 `.package-code-value` / `.station-name` / `.package-tags`），淘宝菜鸟没有稳定结构，退化成「取件码 `\d{1,3}-\d{1,2}-\d{3,6}` + 就近文本找驿站/货架」的启发式。页面变化由 MutationObserver 自动重抓，另有 25 秒定时兜底。

### 站点入口

| 标签 | 官方入口 | 能看到什么 |
| --- | --- | --- |
| 拼多多 | `m.pinduoduo.net/mdkd/package?tab=ID_CODE` | 身份码 + 待取包裹（淘宝/天猫里被拼多多代收的件，主要是圆通） |
| 淘宝取件 | `pages-fast.m.taobao.com/wow/z/uniapp/1100333/last-mile-fe/m-end-school-tab/home` | 驿站/学校 tab 的**待取件列表**（菜鸟那一侧的取件码都在这里） |
| 菜鸟码 | `page.cainiao.com/cn-app-web/identity-code/index.html#/` | 菜鸟官方身份码（登录态与淘宝共用） |

淘宝那个入口特意没用 `end-collect-platform/identity-code` —— 那页**只有身份码、没有包裹列表**，聚合拿不到东西；HandyCode 也是把 `m-end-school-tab/home` 当「待取包裹」入口用的。

### 壳里修掉的三件事

1. **拼多多登录不再跳 App**：`pinduoduo://` / `intent://` / `taobao://` 这类 scheme 一律 `.cancel`，页面里「打开拼多多App」的按钮也拦掉。所以拼多多要在壳内**用扫码或手机验证码登录**，不会再被拽去 App。
2. **淘宝/菜鸟验证码能走完**：实现了 `WKUIDelegate.createWebViewWith`，把 `target=_blank` 的弹窗就地加载（返回 `nil` 不新开窗口），并覆盖 `window.open`。不动这个的话，点「获取验证码」就是没反应。
3. **登录横条不再挤掉表单**：「您需要登录才能继续访问」那条和它的 iframe 会被归零重排。

### 已知代价（诚实说）

- **iOS 第三方 Cookie**：淘宝登录框是 `login.m.taobao.com` 的 iframe，相对菜鸟/淘宝页面属于第三方。Safari/WKWebView 的 ITP 有可能让这类 iframe 登录走不通；走不通时的表现是登录框一直在转或者报错。这需要真机试，试出来的结果再决定要不要改成「先跳整页登录、回来再进列表」。
- **网页端和 App 登录会互踢**：同一账号在网页端登录可能把 App 会话顶掉。稳妥做法是网页端用小号登录，然后在「待取包裹」里加大号的收件手机号并验证。
- 没有 App 图标（装上白图标），要的话下次补。
- 非官方工具，依赖官方网页，平台改版就失效。

### 出包

云编译流水线在 `.github/workflows/ios-unsigned.yml`（GitHub Actions `macos-15` / `macos-latest` 矩阵，XcodeGen + `CODE_SIGNING_ALLOWED=NO`）。推上 GitHub → Actions → 下 artifact → 全能签签名。

> 本机（Windows）编不了 iOS：iOS 二进制要 Apple 的 iOS SDK 链接，本机 `clang`/`swift`/iOS SDK 全没有，WSL 也没装发行版。

详细步骤和踩过的坑在 [ios/BUILD.md](ios/BUILD.md)。

---

## 七、文件

- `pdd-pickup.user.js` —— 脚本本体，方案 B 直接装；方案 C 复用同一段逻辑
- `_syntax-check.html` —— 用来在浏览器里自检脚本能不能正常加载（打开它应该显示 `SCRIPT LOADED OK`）

## 八、风险声明

非官方的个人使用工具，依赖拼多多官方网页，平台改版就会失效。请以学校驿站实际要求为准。
