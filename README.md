# 茉莉取件 · 拼多多 / 菜鸟取件码聚合（iOS + Android）

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

| 版本 | 日期 | 改了什么 |
| --- | --- | --- |
| 0.12.2 | 2026-11-14 | 修「拼多多标签里点『整页登录』跳成淘宝登录页」：那个按钮之前是无条件挂的、安卓侧还写死拼 login.taobao.com，现在只在菜鸟/淘宝标签显示，拼多多点了会提示走它自己的网页登录；淘系 SSO 确认页的「快速进入」改为自动替你点一次（那屏点它是在网页内完成 SSO，不跳 App）；安卓诊断重写成和 iOS 一样详细（每站 url/title/正文长度/帧数/抓到的条目/拼多多改路日志/mtop 返回码/导航链/cookie 分域统计/菜鸟原生接口 ret+raw）|
| 0.12.1 | 2026-11-14 | 两端底栏顺序对齐为「首页 / 菜鸟取件 / 拼多多 / 淘宝取件」（之前 iOS 是拼多多在前）；其余同 0.12.0 |
| 0.12.0 | 2026-11-14 | 悬浮按钮里加**「清除登录」**（两端），换拼多多/淘宝号不用重装 App；安卓底栏补上和 iOS 一样的图标（🏠📦🛒🏷）+ 间距对齐；拼多多「确认继续用当前账号登录」页那个点了没反应的「快速进入」改成藏掉并给出提示，引导走「使用其他账号登录」 |
| 0.11.0 | 2026-11-14 | 安卓端补上**截图识别取件码**（ML Kit 中文离线模型随包，不联网）：首页「＋ 添加」里可以「从图库选图 / 拍一张」，认出码后多选加入首页，能顺带认驿站名；版本号与 iOS 对齐 |
| 0.10.1 | 2026-11-14 | 应用改名为**茉莉取件**；加上应用图标（两张平台各自生成 1024 / 五档 mipmap）；修安卓「看不到悬浮按钮」——之前把整个悬浮容器连主按钮一起设成了 `GONE`，现在容器常显、只收起菜单项，且悬浮按钮只在站点页出现 |
| 0.10.0 | 2026-11-14 | 界面改版：站点页右上角那排小胶囊换成**右下角悬浮按钮**（点一下展开：整页登录 / 刷新页面 / 回到入口 / 抓一次，再点收起）；底部标签栏加图标、字号和间距放大；**新增安卓版**（`android/`，同一套逻辑：网页只做登录 + 兜底抓取，菜鸟列表走原生 mtop），CI 出**自签 release APK**，装上即用、可覆盖升级 |
| 0.9.3 | 2026-11-14 | 首页加**登录失效横幅**：菜鸟接口回 `SESSION_EXPIRED`/`TOKEN_EMPTY`/`NEED_LOGIN` 时，首页顶部出现「淘宝登录已失效 → 点这里重新登录」，点一下自动切到菜鸟标签并打开 `login.taobao.com` 迷你登录页；登录成功后横幅自动消失。原因：重装 App（全能签重签也一样）会清空 WKWebView 的 cookie 存储，淘宝登录态丢光，首页只会显示「没抓到」，不给入口就回不来 |
| 0.9.2 | 2026-11-14 | 取件码支持**顺丰形态** `B-13016`（1~3 个字母 + 破折号 + 数字）：`normalize` 统一大写、`looksLikeCode` 放开为「字母-数字」与「数字-数字[-数字]」两种、OCR 正则同步、网页抓取正则同步、菜鸟 JSON 解析单独收紧（末段 ≥3 位，避免把 `2026-11` 这种日期当取件码）。手动录入提示改成两种格式都说明 |
| 0.9.1 | 2026-11-14 | 修 0.9.0 驿站名取错（显示成「校园快递服务中心」甚至整条「广东省广州市…」地址）：改成打分制 —— 含「驿站」最高（+5），自提点/服务站/快递柜/超市/便利店/门卫/收发室（+3），「服务中心」（+1）；带省/市/区/县/镇/街/路/号/栋/楼/室的串一律判为地址、不参与评选。诊断页「菜鸟接口」常驻输出 raw 样本（2000 字）+ 全部条目前 12 条，便于继续对齐真实字段名 |
| 0.9.0 | 2026-11-14 | 菜鸟「取包裹」改成**原生 mtop 调用**（新增 `Mtop.swift` + `Cainiao.swift`）：网页里 JS 在 `page.cainiao.com` 下读不到 `.taobao.com` 的 `_m_h5_tk` 签名 token，所以 mtop 永远回 `FAIL_SYS_SESSION_EXPIRED`；原生从 `WKHTTPCookieStore` 取全部 cookie、自己算 `md5(token&t&appKey&data)` 签名、自己带 Cookie 头直连 `acs.m.taobao.com`，绕开跨站限制。返回 JSON 不硬编码字段，递归扫「数字-数字-数字」形状取码 + 兄弟字段取驿站/货位 |
| 0.8.0 | 2026-11-14 | 给淘宝/菜鸟的 WebView 换 **Safari 版 UA**（WKWebView 默认 UA 没有 `Safari/604.1`，阿里系据此判定「App 内嵌 WebView」→ 登录降级、走不完整）；诊断页改成按域名统计 cookie + 点名检查 `cookie2/_tb_token_/unb` 等会话 cookie；新增 mtop 返回码记录（`acs.m.taobao.com` 的 `ret`），用来区分「没登录」和「登录了但接口拒」 |
| 0.7.0 | 2026-11-14 | 新增「菜鸟取件」标签：菜鸟官方 H5 取包裹页 `page.cainiao.com/xiniao-web/xn-h5-gg-tab-closed-takeParcel/#/`（内部调 `mtop.cainiao.lpc.packageservice.xiniao.querypacklist`），未登录时是「包裹加载中…」骨架屏，需淘宝整页登录；「身份码」标签按用户要求撤掉 |
| 0.6.0 | 2026-11-14 | 首页加「＋ 添加」：能手动输入取件码，也能选相册截图/拍照，用系统 Vision 在本机 OCR 抠出所有取件码一键加入；手动录入会持久保存（标「手动」并可删除） |
| 0.5.0 | 2026-11-14 | 「菜鸟码」标签换成淘宝「代收身份码」——菜鸟那页在壳里只会弹「用菜鸟App扫码添加」，网页端没绑定入口；淘宝这页同域、登录态直接可用 |
| 0.4.0 | 2026-11-14 | 登录成功跳回来时自动补一次 reload（修「菜鸟登录后又弹回登录页」）；诊断页加 Cookie 数量与主框架导航链；标签栏加常驻提示 |
| 0.3.0 | 2026-11-14 | 抓取合并「官方 DOM + 通用启发式」并按码去重（修拼多多只认出第一件）；取件码支持全角破折号；所有 http(s) 一律留在壳内，不再把登录流程踢去 Safari |
| 0.2.0 | 2026-11-14 | 拼多多**登录页**也做同源改路（修「登录完弹回登录页」）；加「诊断」页；淘宝/菜鸟加「整页登录」；产物名带版本号 |
| 0.1.0 | 2026-11-14 | 首页聚合三个站点、拼多多不跳 App、淘宝入口换 school-tab |

产物命名：`dist/PickupCode-<版本>-unsigned.ipa`，版本号来自 `ios/project.yml` 的 `MARKETING_VERSION`，由流水线自动写进文件名和 artifact 名。

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

### 壳里修掉的四件事

1. **拼多多登录不再跳 App**：`pinduoduo://` / `intent://` / `taobao://` 这类 scheme 一律 `.cancel`，页面里「打开拼多多App」的按钮也拦掉。所以拼多多要在壳内**用扫码或手机验证码登录**，不会再被拽去 App。
2. **拼多多登录不再弹回登录页**（v0.2.0）：登录页自己也发 `POST https://api.pinduoduo.com/api/apoc/binding/mobile/...pre/check`，跨站 424，会话永远建立不起来。现在**登录页/验证页同样做同源改路**（`api.pinduoduo.com/api/` → `m.pinduoduo.net/proxy/api/api/`），不再按页面路径跳过。
3. **淘宝/菜鸟验证码能走完**：实现了 `WKUIDelegate.createWebViewWith`，把 `target=_blank` 的弹窗就地加载（返回 `nil` 不新开窗口），并覆盖 `window.open`。不动这个的话，点「获取验证码」就是没反应。走不通时点标签页右上角的「**整页登录**」，直接开 `login.taobao.com` 并带 `redirectURL` 回到入口，绕开第三方 Cookie 的 iframe。
4. **登录横条不再挤掉表单**：「您需要登录才能继续访问」那条和它的 iframe 会被归零重排。

### 出问题怎么查

首页右上角有「**诊断**」按钮：一次把三个站点此刻的 URL、标题、`readyState`、正文长度、正文开头 160 字、有没有「登录中」字样、拼多多卡片数、iframe 列表、抓到的件、**同源改路次数与最近 30 条映射记录**、页面自己的 `console.error/warn` 全拉出来，可全选可一键复制。真机上报错就复制这段，能直接看出是「没登录」「被拦」「改路没生效」还是「DOM 改版」。

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

## 六点五、安卓版（`android/`）

和 iOS 版同一套逻辑，纯原生 Java（不用 AndroidX/Compose，依赖只有 AGP，CI 跑得快）：

- 网页只负责**登录 + 兜底抓取**；菜鸟「取包裹」列表由 `Mtop.java` 走原生 mtop 拿
  （`mtop.cainiao.lpc.packageservice.xiniao.querypacklist`，appKey `12574478`，
  签名 `md5(_m_h5_tk 的 token + "&" + t + "&" + appKey + "&" + data)`）。
  为什么不在网页里调：签名 token 存在 `.taobao.com` 域的 `_m_h5_tk` 里，
  菜鸟页 JS 跑在 `page.cainiao.com`，读不到别的域的 cookie，签名必错。
- 安卓侧 cookie 用 `CookieManager.getCookie("https://www.taobao.com")` 取
  （按 URL 域名匹配，`.taobao.com` 上的票才会一起带出来）。
- UI：底栏四个标签（首页 / 菜鸟取件 / 拼多多 / 淘宝取件），站点页右下角**悬浮按钮**展开
  登录 / 刷新 / 回入口 / 抓一次；首页可手动添加取件码、可看诊断。
- 打包：`.github/workflows/android.yml`（`ubuntu-latest` 自带 Android SDK，Gradle 8.7 + AGP 8.5.2），
  产物 `PickupCode-<ver>-android.apk`，用仓库里的 `android/keystore.jks` 自签，
  **可以直接装、也能覆盖升级**（debug 密钥每次构建都不同，装第二次就得卸载，所以没用 debug）。

> 本机没有 Android SDK / Gradle，安卓包同样只能在 CI 里出。

---

## 七、文件

- `pdd-pickup.user.js` —— 脚本本体，方案 B 直接装；方案 C 复用同一段逻辑
- `_syntax-check.html` —— 用来在浏览器里自检脚本能不能正常加载（打开它应该显示 `SCRIPT LOADED OK`）

## 八、风险声明

非官方的个人使用工具，依赖拼多多官方网页，平台改版就会失效。请以学校驿站实际要求为准。
