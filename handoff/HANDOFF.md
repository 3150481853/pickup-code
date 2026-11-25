# 茉莉取件 · 安卓端交接与客制化说明

> 版本基准：**0.15.1（versionCode 25）** · 2026-11-15
> 完整仓库（含 iOS 端与全部历史）：https://github.com/3150481853/pickup-code
> 本文档只讲安卓（APK），iOS 那套需要 macOS/云编译 + 自签，跟这份交接无关。

---

## 0. 这东西解决什么问题

校园驿站（例：多多买菜·广软多多驿站）取件，官方流程是：打开拼多多/菜鸟 → 点身份码 → 等页面加载 → 在一堆推荐广告里找那个码。一天三个件就要重复三次。

茉莉取件做的事：**用系统 WebView 加载各平台官方网页，把「取件码 / 驿站 / 货位 / 快递单号 / 主图」抓出来，汇总到自己做的首页列表里**。免广告、离线可看、点一下就复制取件码。

两条数据来源：

| 来源 | 拿什么 | 怎么拿 |
|---|---|---|
| 拼多多 | 待取包裹列表（代收点件） | 网页 + JS 注入抓 DOM |
| 菜鸟 | 「取包裹」列表（淘宝/天猫件） | **原生调 mtop 接口**（不是网页，见 §2.2） |

不做的三件事（都是坑，别浪费时间去试）：

- ❌ 微信小程序：`<web-view>` 只能加载自己备案过的业务域名（要放校验文件），`m.pinduoduo.net` 配不进去，且小程序禁止注入脚本。
- ❌ 逆向官方 APK：拿到的还是同一套 mtop 接口和同一份登录态；App 内 SSO 靠包名/签名校验，WebView 借不到，反而要自己扛风控。
- ❌ 指望「10 分钟自动归档」去判断哪个件被取走了：菜鸟接口按「近 30 天」返回，取走的件还会一直回来（§7.6）。

---

## 1. 五分钟改成你自己的包

只改 4 个地方就能和别人的包共存、也能覆盖安装你自己的历史版本。

### 1.1 改包名（必须改，否则和他的包冲突）

`android/app/build.gradle`

```gradle
android {
    namespace 'local.pickup'                 // 代码里的包名，改不改都行
    defaultConfig {
        applicationId "local.pickup.android" // ← 改这里，例如 com.yourname.pickup
    }
}
```

改完还要同步改 `android/app/src/main/AndroidManifest.xml` 里 provider 的 authority（否则两个包会抢同一个 content provider）：

```xml
android:authorities="local.pickup.shots"   <!-- 改成 com.yourname.pickup.shots -->
```

同时改 `ShotProvider.java` 里的 `AUTHORITY` 常量（与上面保持一致）。

### 1.2 改 App 名字

`android/app/src/main/AndroidManifest.xml`：

```xml
android:label="茉莉取件"
```

（中文直接写在这里就行，不要写进 `strings.xml` 再引用，这个工程没有 res/values/strings.xml。）

### 1.3 换图标

五档尺寸，直接覆盖（建议 1024×1024 原图居中裁正方形后缩放）：

```
android/app/src/main/res/mipmap-mdpi/ic_launcher.png      48×48
android/app/src/main/res/mipmap-hdpi/ic_launcher.png      72×72
android/app/src/main/res/mipmap-xhdpi/ic_launcher.png     96×96
android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png    144×144
android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png   192×192
```

### 1.4 换签名（强烈建议）

仓库里自带的 `android/keystore.jks` 是**我和你自己用**的（密码 `pickup123`、alias `pickup`）。你客制化就自己生成一个，否则将来换机器/换人签名对不上，升级必须先卸载（丢数据）。

```bash
keytool -genkeypair -v -keystore keystore.jks -alias pickup \
  -keyalg RSA -keysize 2048 -validity 10950 \
  -storepass 你的密码 -keypass 你的密码 \
  -dname "CN=yourname, OU=dev, O=dev, L=, ST=, C=CN"
```

然后把 `android/app/build.gradle` 的 `signingConfigs.release` 里三个值换掉。

> **为什么不用 debug 签名**：CI 上每次跑 `assembleDebug` 生成的 debug key 都不一样，装第二个版本时系统会判定签名不同，必须先卸载旧版。release + 固定 keystore 才能一路覆盖升级（本地数据、登录态都保留）。

---

## 2. 三条必须知道的技术真相

这三条是我踩了几十次包才确认的，照抄能省你两天。

### 2.1 拼多多：跨站请求一律 424，只能「同源改路」

拼多多身份码页的 H5 部署在 `m.pinduoduo.net`，但业务请求发往 **跨站的** `api.pinduoduo.com`。WebView 里这些请求不带会话 Cookie，服务端直接回 **424**，然后页面弹回登录页 —— 表现为「登录完又跳回登录界面」。

实测证据（桌面 Chrome，登录前）：

```
POST https://api.pinduoduo.com/api/express_trackbox/station/package        → 424
POST https://api.pinduoduo.com/api/apoc/binding/mobile/.../pre/check       → 424
GET  https://m.pinduoduo.net/login.html?from=...                           → 200
GET  https://m.pinduoduo.net/proxy/api/api/galen/grayscale?...             → 200   ← 同源路由是好的
```

修法：把 `https://api.pinduoduo.com/api/` 重写成 `https://m.pinduoduo.net/proxy/api/api/`。

> **注意 `/proxy/api/api/` 里两个 api 是故意的**：`/proxy/api` 是代理前缀，`/api/` 是原路径的一部分。少写一个就 404。

**关键细节：登录页自己也要发这个跨站请求**（登录校验 `.../pre/check`），所以**不能**只在业务页改路、登录页不改 —— 我就是这么把 0.2.0 之前的所有版本卡在「登录完弹回登录页」的。做法是**全站无条件改路**，见 `assets/inject-pdd.js` 里的 `mapUrl()`。

实现方式（`inject-pdd.js`，`@run-at document-start` 等价：注入在页面脚本之前）：

```js
var FROM = 'https://api.pinduoduo.com/api/';
var TO   = 'https://m.pinduoduo.net/proxy/api/api/';
// 包住 fetch / XMLHttpRequest.prototype.open / navigator.sendBeacon
// 用 indexOf 位置替换（兼容 http://、协议相对 //）
```

调试：`window.__pddMap = { count, log }` 里存最近 30 条改写记录，诊断页会打出来。

### 2.2 菜鸟/淘宝：签名 token 在别的域，网页 JS 拿不到 → 必须原生调用

菜鸟「取包裹」其实有网页版：`https://page.cainiao.com/xiniao-web/xn-h5-gg-tab-closed-takeParcel/#/`，数据走 mtop：

```
GET https://acs.m.taobao.com/h5/mtop.cainiao.lpc.packageservice.xiniao.querypacklist/1.0/
    ?appKey=12574478&t=...&sign=...&api=...&data={"staId":"","day":30,"needAuthControl":true}
```

在 WebView 里跑**永远是** `FAIL_SYS_SESSION_EXPIRED`，即使 cookie 全都齐了（我验过：`.taobao.com` 35 条、`cookie2/_tb_token_/unb/_l_g_/sgcookie/_m_h5_tk/cna` 一个不缺）。

**根因**：mtop 的 `sign` 需要 `_m_h5_tk` 里的 token，而 `_m_h5_tk` 是 **`.taobao.com`** 域的 cookie；菜鸟页的 JS 运行在 `page.cainiao.com`，同源策略下**读不到别的域的 cookie**，所以拿不到 token、签名必错。这不是登录问题，是结构上不可能成功。

冷知识：先给 WebView 换 Safari UA（`Version/x Mobile/15E148 Safari/604.1`）也不够 —— 那只是让阿里系别把它当「App 内嵌 WebView」，签名仍要 token。

**解法：在原生侧直接调 mtop**（`Mtop.java`）：

1. `CookieManager.getCookie("https://www.taobao.com")` —— **必须用 `www.taobao.com` 这个 URL**，否则 `.taobao.com` 上的票不会带出来；
2. 从 cookie 串里取 `_m_h5_tk`，按 `_` 切开取前半段当 token；
3. `sign = md5(token + "&" + t + "&" + "12574478" + "&" + data)`；
4. GET `https://acs.m.taobao.com/h5/<api>/1.0/?jsv=2.7.2&appKey=12574478&t=<毫秒>&sign=<md5>&api=<api>&v=1.0&type=originaljson&dataType=json&timeout=20000&data=<payload>`，头带 `Cookie`、Safari UA、`Referer: https://page.cainiao.com/`。

返回结构没有公开文档，所以 `Mtop.Parser` 是**递归扫 JSON**：认出「三段数字码」（`112-3-13061`）就当一条包裹，再从同一层里挑驿站名/货位/单号/主图。

**两个必须处理的坑**：

- 驿站名常常藏在 `feature2` 这个**被转义过一次的 JSON 字符串**里（`{"stationOrderPickUpCode":"90990","postName":"广软多多驿站",...}`）。不把它解开二层，就永远只能拿到「校园快递服务中心」或者空。
- 字段值里有大量噪声：`true`、经纬度 `23.451012`、区域 ID `440184`、伪单号 `50000000000049`。必须做白名单 + 合法性过滤（`Mtop.Parser.isJunk`），否则首页会显示垃圾。

### 2.3 拼多多登录态：网页端和官方 App 会互相顶掉同名会话

同一账号在网页端和拼多多 App 里都重新登录过，先登的那个会被踢。作者（HandyCode）的建议是：网页端用小号登录，再在站点里「添加并验证」大号收件手机号。

**衍生的产品事实**：拼多多「待取包裹」列表是**服务端**按「已验证手机号 + 手动添加的运单号」决定的。小号看不到主号买的件，这不是注入脚本能改的 —— 只能在小号里手动「添加快递」运单号，或者用主号登录。

---

## 3. 代码地图

```
android/
├── settings.gradle / build.gradle / gradle.properties    AGP 8.5.2 + Gradle 8.7，Java 17
├── keystore.jks                                          自签密钥（密码 pickup123，alias pickup）
└── app/
    ├── build.gradle                                      minSdk 24 / target 34 / versionCode / versionName
    └── src/main/
        ├── AndroidManifest.xml                           权限、label、icon、ShotProvider
        ├── assets/
        │   ├── shim.js         （0.7K）  把 window.Pickup.post 包成 iOS 那套 messageHandlers 形状
        │   ├── inject-pdd.js   （13K）   拼多多：同源改路 + 藏广告 + 登录确认页引导
        │   ├── inject-taobao.js（2.7K）  淘系：藏「请登录」横条、修 iframe 顶部占位
        │   └── pickup-agent.js （20K）   抓取核心：DOM/启发式双路取码、主图、单号、诊断
        ├── res/mipmap-*/ic_launcher.png                  图标五档
        └── java/local/pickup/
            ├── MainActivity.java  （68K） 全部 UI：底栏/悬浮按钮/列表/左划/分享/录入/OCR/诊断
            ├── Store.java         （20K） 状态机：合并去重、置顶、划走、已取归档、疑似出库
            ├── Mtop.java          （20K） mtop 签名调用 + 菜鸟 JSON 解析（扫码/驿站/货位/单号/主图）
            ├── PickupItem.java    （1K）  一条包裹：code/site/station/place/mailNo/img
            ├── ShareCard.java     （3K）  Canvas 画分享图（1080 宽）
            └── ShotProvider.java  （2K）  FileProvider 替身，给相机写临时文件（Android 7+ 不许 file://）
```

### 数据是怎么流到首页的

```
WebView 加载官方页
   └─ inject(..) 先 shim.js，再站点脚本，最后 pickup-agent.js
         └─ agent 抓 DOM → window.Pickup.post([...])   ← shim 转发
               └─ Bridge.post（@JavascriptInterface）
                     └─ Store.setCollected(site, list, state) → republish() → 首页列表

菜鸟那条不走网页：
Cainiao.query() ── Mtop.call(querypacklist) ── 解析 JSON ── Store.setCollected("cainiao", ...)
                                                  （每 45 秒一次）
```

刷新节奏：进 App 全量刷一次；每 25 秒让三个 WebView 各抓一次；菜鸟接口每 45 秒一次；`Store.archiveMissingIfNeeded()` 每 20 秒巡一次「疑似已出库」的 10 分钟宽限。

---

## 4. 打包

### 4.1 推荐：GitHub Actions（本机什么都不用装）

`.github/workflows/android.yml` 已经在仓库里，push 到 `main` 只要动了 `android/**` 就会自动出包。核心三步：

```yaml
- uses: actions/setup-java@v4
  with: { distribution: temurin, java-version: '17' }
- uses: gradle/actions/setup-gradle@v3
  with: { gradle-version: '8.7' }
- run: cd android && gradle assembleRelease --no-daemon --stacktrace
```

产物名由 `versionName` 自动拼：`PickupCode-<versionName>-android.apk`。

自己开一个空仓库、把本目录 `src/android` + `.github/workflows/android.yml` 推上去即可。第一次跑大约 3~5 分钟（要下 ML Kit 依赖，之后有缓存）。

### 4.2 本机打包

需要：JDK 17、Android SDK Platform 34、Gradle 8.7（或直接用 `gradlew`，但本工程没带 wrapper，也可以直接装个 Gradle）。

```bash
cd android
gradle assembleRelease
# 产物：app/build/outputs/apk/release/app-release.apk
```

我这边（Windows）没有装 Android SDK，所以全部构建都在 CI 上跑；本地只做 **javac 语法检查**：

```bash
javac -encoding UTF-8 -d /tmp/out app/src/main/java/local/pickup/*.java
# 预期只剩 "程序包 android.* 不存在 / 找不到符号 org.json" 这类错误，其他都是真错
```

> ⚠️ 注意：只过滤「包不存在」类错误是不够的。0.13.0 我写了个 `refreshHome()`（正确是 `renderHome()`），本地 javac 把它当成缺 android 包的级联错误过滤掉了，直到 CI 才报 `cannot find symbol: method refreshHome()`。**改完方法调用后，建议 grep 一遍新方法名确认拼写，或者干脆以 CI 为准。**

### 4.3 覆盖安装 vs 新装

- 同一个 `applicationId` + 同一个签名 → 直接覆盖安装，登录态和手动录入都保留。
- `applicationId` 变了 / 签名变了 → 系统当两个 App，必须卸载重装（数据全丢，淘宝和拼多多都要重登）。

---

## 5. APK 迭代记录

| 版本 | APK 大小 | 关键改动 | 教训 |
|---|---|---|---|
| 0.10.0 | 38 KB | 安卓版首发：纯 Java + AGP，复用 iOS 的注入脚本；悬浮按钮 + 底栏图标 | `ListView` 都没用，全手写 View |
| 0.10.1 | 132 KB | 改名「茉莉取件」、五档图标、**修悬浮按钮不显示** | 我把整个 `fabBox` 设成 GONE，主按钮也在里面 → 菜单和按钮一起消失 |
| 0.11.0 | 19.5 MB | 截图识别取件码（ML Kit 中文离线模型，随包打包） | `ChineseTextRecognizerOptions.Builder()` 少了 `new` → 编译失败 |
| 0.12.0 | 41.9 MB | 两端「清除登录」（换号不用卸载）、安卓底栏图标对齐 iOS、拼多多登录确认页引导 | 用 pwsh 的 here-string 改 build.gradle，中文注释变乱码 + 换行被吃，签名配置整段失效 |
| 0.12.1 | 41.9 MB | 底栏顺序与 iOS 对齐（首页/菜鸟/拼多多/淘宝） | 重排 `Sites.all` 时漏了块间逗号；`continue-on-error` 让 job 显示绿但 leg 失败，要查 `/jobs` |
| 0.12.2 | 41.9 MB | 「整页登录」只给淘系；淘系 SSO 自动点「快速进入」；安卓诊断对齐 iOS（导航链/分域 cookie/mtop 返回码） | 「整页登录」在安卓是**无条件**加载淘宝登录页，拼多多标签点了也进淘宝 → 用户直接发现 |
| 0.13.0 | 41.9 MB | 首页左划置顶/删除、分享取件码成图、选图按新→旧、菜鸟解析解转义 JSON | `ACTION_GET_CONTENT` 调的是「文件」App，按文件名排序 → 看着像「老照片在前」，要用 `ACTION_PICK_IMAGES` |
| 0.14.0 | 41.9 MB | 每条左侧主图 + 快递单号；手填/识别都能补单号 | 主图一开始按「第一个 http 串」取，取到快递 logo / 广告图 |
| 0.14.2 | 41.9 MB | iOS 端修「滑不动」；安卓同步行为 | **真凶是手势**：`ScrollView` + 每行 `simultaneousGesture` 抢走了竖向滚动，跟图片加载无关 |
| 0.14.3 | 41.9 MB | 主图两档（商品图优先、logo 兜底）；菜鸟筛掉已签收/已取件 | 上一版把所有 logo 都排掉，结果整列都是占位图标 |
| 0.15.0 | 41.9 MB | 名单比对（少了的打「疑似已出库」、10 分钟后归档）、左划「已取」、拿快递模式、归档可放回 | — |
| 0.15.1 | 41.9 MB | **修归档码被源灌回首页**；菜鸟货位/单号过滤垃圾值 | 只从内存名单摘掉没用，轮询会灌回来；`true`/经纬度/伪 ID 被当成字段 |

体积说明：41.9 MB 里绝大部分是 ML Kit 中文离线识别模型（`assets/mlkit-google-ocr-models/**`）。如果不需要截图识别，删掉 `build.gradle` 里的 ML Kit 依赖 + `ocr()/ShotProvider` 相关代码，包能瘦到 200 KB 以内。

---

## 6. 踩坑清单（按代价从高到低）

1. **不要用 PowerShell 的 here-string / `Set-Content` 改含中文的源码文件**。本机 pwsh 5.1 会把 UTF-8 读成 ANSI，写回去中文变乱码，**还会吃掉换行**（`build.gradle` 的 `storeFile` 被并进注释里，签名静默失效）。改文件用编辑器/`write` 工具，或 Python `io.open(..., encoding='utf-8', newline='\n')`。
2. **`continue-on-error: true` 会骗你**。iOS 构建有个 `macos-15` leg 长期失败（`The configuration 'macos-14-arm64-us-default' is not supported` 之后遗症），job 整体仍显示 ✅，产物来自另一个 leg。看构建结果要查 `/actions/runs/<id>/jobs`。
3. **`ACTION_GET_CONTENT` ≠ 相册**。它调「文件」App，默认按文件名升序。要「最近在前」用 Android 13+ 的 `MediaStore.ACTION_PICK_IMAGES`，低版本用 `Intent.ACTION_PICK` + `EXTERNAL_CONTENT_URI`。
4. **WebView 里图片加载卡列表，通常不是图片的锅**。先看有没有自定义手势（`setOnTouchListener` / SwiftUI 的 `simultaneousGesture`）在抢滚动；安卓这边还有第二个坑：在主线程 `BitmapFactory.decodeStream` 解 800×800 原图。用 `HttpURLConnection` + 子线程 + `LruCache` + 按显示尺寸缩放（`loadThumb()` 就是干这个的）。
5. **`@JavascriptInterface` 桥是同步阻塞的**，不要在 `Bridge.post` 里干重活；`Store.republish()` 里也尽量别做 IO（我是攒批）。
6. **菜鸟接口 `day: 30` 是「近 30 天」**，取走的件照旧返回。判定「已出库」只能靠：本地归档记录 / 状态字段 / 用户手动点。别指望名单自己消失。
7. **JSON 里的字符串是脏的**。`true`、`23.451012`（经纬度）、`440184`（区域 ID）、`50000000000049`（伪单号）都会混进「候选项」。挑字段一定要：先按 key 名白名单（`postName`/`daishouName`/`mailNo`/`img`…），再按值做合法性校验（`isJunk()`）。
8. **驿站名可能藏在转义 JSON 里**。`feature` / `feature2` 的值是一段字符串形式的 JSON，要 `new JSONObject(str)` 再解一层。
9. **`CookieManager.getCookie(url)` 的 URL 决定带哪些 cookie**。取淘宝票必须传 `https://www.taobao.com`，传 `page.cainiao.com` 就只剩菜鸟域的。
10. **Android 7+ 不许 `file://` 跨 App 传文件**。相机写图要么 `FileProvider`，要么像本工程这样用一个最小 `ContentProvider`（`ShotProvider`）。
11. **`minifyEnabled` 别急着开**。开了 R8 之后 `@JavascriptInterface` 方法名可能被混淆，JS 侧就调不到了（要么 keep 规则，要么保持关闭 —— 本工程是关闭的）。
12. **首次安装后必须各登录一次**（拼多多用网页手机号/扫码；菜鸟走「整页登录」登淘宝）。「清除登录」在悬浮菜单里，换号不用卸载。

---

## 7. 想加东西怎么改（recipe）

### 7.1 再加一个驿站/站点

1. `MainActivity.java` 顶部四个常量加一组：`TABS`、`TAB_ICONS`、`SITE_IDS`、`ENTRIES`（数组下标必须一一对应，`0` 固定是首页）；
2. `ensureWeb(idx)` 会自动按 `SITE_IDS` 建 WebView，`inject()` 按 `site` 选脚本 —— 新站点需要一个新的 `assets/inject-xxx.js`（不需要就传空）；
3. `Store.SITE_NAME` 加显示名；
4. `hintText(idx)` 加一句顶部提示。

### 7.2 改抓取规则（最常改的地方）

全在 `assets/pickup-agent.js`：

- `collectPdd()` —— 拼多多的官方 DOM 类名（`[class*="package-list-picking"]`、`[class*="package-code-value"]`、`.station-name`）。拼多多改版后**优先改这里**；
- `collectGeneric()` —— 启发式兜底：正则找「数字-数字-数字」，再爬到卡片层读驿站/货位。任何新站点都能靠它先跑起来；
- `CODE` / `CODE_G` —— 取件码形状。现在支持全角破折号、顺丰 `B-13016` 这种「字母-数字」；
- `imgOf()` / `mailNoOf()` —— 主图与单号打分（宁可不显示，也不要放错）。

改完用 `esprima` 做语法检查（`pip install esprima`）：

```python
import esprima, io
esprima.parseScript(io.open('pickup-agent.js', encoding='utf-8').read())
```

改完记得**同步到两端**：iOS 在 `ios/PickupCode/Resources/`，安卓在 `android/app/src/main/assets/`。

### 7.3 改 UI / 配色

- 主色：`MainActivity.java` 里搜 `Color.rgb(233, 36, 76)` 一类常量（红线/红胶囊）；
- 底栏：`buildTabBar()`；悬浮菜单：`buildFab()` / `toggleFab()`；
- 列表行：`row(PickupItem)`（含左划三按钮、缩略图、徽章）；空态：`renderHome()` 里的 `if (items.isEmpty())`。

### 7.4 加通知 / 桌面小组件

数据都在 `Store.items`（`List<PickupItem>`）。注意 `Store` 是普通类不是 Service，做后台轮询要自己起 `WorkManager`（会引入新依赖）——最省事的做法是只做「打开 App 后立即刷新」，别做后台常驻，阿里系的会话在后台也容易被风控。

---

## 8. 已知限制

- **淘宝登录可能撞滑块验证**。撞了就只能在「菜鸟取件」标签里手动过验证（壳内会就地打开，不跳浏览器）。
- **拼多多的待取列表由服务端决定**（已验证手机号 + 手动添加的运单号）。小号登录看不到主号的件，这不是 bug。
- **每次重装都会清 WebView cookie**（自签 App 换签名/换包名更是如此），重装后要重新登录一次。
- **只在本人手机上验证过**（OPPO PLA110 / Android 16 与 iPhone）。其他厂商 ROM 的 WebView 内核差异可能影响注入时序，遇到抓不到先看「诊断」页里的 `bodyLen` 和 `console`。
- **抓取依赖对方页面结构**，拼多多/菜鸟改版就会失效。这是这类工具的天生成本 —— 所以 `pickup-agent.js` 里同时留了官方 DOM 和通用启发式两条路。

---

## 9. 隐私与免责

- 全部数据只在本机：`SharedPreferences`（手动录入、置顶、归档）+ WebView cookie。**没有任何自建服务器、没有统计 SDK、没有上传**。
- 只在 `INTERNET` / `ACCESS_NETWORK_STATE` 两个权限之外没有任何敏感权限；相机/相册只在截图识别时用，图片不出本机。
- 这是个人自用工具，用的是你自己的账号、自己的驿站。请勿拿去做批量查询/代取他人包裹 —— 那会踩平台规则和个人信息保护的红线。

---

## 10. 附件清单

```
HANDOFF.md                      本文
VERSIONS.md                     每个版本的构建记录（版本号 / versionCode / 体积 / commit）
apk/PickupCode-0.15.1-android.apk   可直接安装的成品（自己签名可用）
src/android/**                  安卓工程源码（直接 gradle assembleRelease）
src/workflow-android.yml        GitHub Actions 流水线（放进 .github/workflows/android.yml）
```
