# 构建记录（APK 侧）

仓库：https://github.com/3150481853/pickup-code
构建环境：GitHub Actions `ubuntu-latest` + JDK 17 + Gradle 8.7 + AGP 8.5.2
产物命名：`PickupCode-<versionName>-android.apk`（workflow 从 `versionName` 自动取）

## 版本表

| versionName | versionCode | 日期 | 体积 | commit | 主题 |
|---|---|---|---|---|---|
| 0.10.0 | 13 | 2026-11-14 | 37,931 B | `20a873d` | 安卓首版（悬浮按钮 + 底栏） |
| 0.10.1 | 14 | 2026-11-14 | 132,167 B | `8ad3807` | 改名「茉莉取件」+ 图标 + 修悬浮按钮 |
| 0.11.0 | 16 | 2026-11-14 | 19,503,010 B | `547eb97` | 截图识别（ML Kit 中文离线模型） |
| 0.12.0 | 16 | 2026-11-14 | 41,881,304 B | `4ce2699` | 清除登录 + 底栏图标 + 登录确认页引导 |
| 0.12.1 | 17 | 2026-11-14 | 41,881,304 B | `ff95663` + `3695bca` | 底栏顺序对齐 iOS |
| 0.12.2 | 18 | 2026-11-14 | 41,881,792 B | `0fa05ba` | 整页登录只给淘系 + SSO 自动确认 + 诊断重写 |
| 0.13.0 | 19 | 2026-11-14 | 41,882,232 B | `2982364` + `3a066a6` | 左划置顶/删除 + 分享图 + 选图新→旧 + 菜鸟解转义 JSON |
| 0.14.0 | 20 | 2026-11-14 | 41,883,020 B | `f35d5cb` | 主图 + 快递单号 |
| 0.14.2 | 22 | 2026-11-14 | 41,883,416 B | `3eb671c` | 与 iOS 行为对齐（列表手势修复） |
| 0.14.3 | 23 | 2026-11-14 | 41,883,392 B | `4934375` | 主图两档（商品图优先 / logo 兜底）+ 筛已签收 |
| 0.15.0 | 24 | 2026-11-15 | 41,883,388 B | `7c18261` | 名单比对 + 左划已取 + 拿快递模式 + 归档可放回 |
| 0.15.1 | 25 | 2026-11-15 | 41,883,392 B | `05e33c0` | 归档码不再被源灌回 + 货位/单号过滤垃圾值 |

> 0.14.1 只出过 iOS 包（安卓同版本号未单独发布），所以安卓侧从 0.14.0 直接跳到 0.14.2。

## 体积变化的三次台阶

1. `0.10.0 → 0.10.1`：+94 KB，加了五档图标（PNG）。
2. `0.10.1 → 0.11.0`：+19.4 MB，引入 `com.google.mlkit:text-recognition-chinese:16.0.0`，中文离线识别模型随包打包。
3. `0.11.0 → 0.12.0`：+22.4 MB，`android.useAndroidX=true` 引入 AndroidX 依赖树（ML Kit 传递依赖需要它）。

**想瘦身**：删 ML Kit 依赖 + `ocr()` / `showOcrResult()` / `ShotProvider` 三块代码，APK 可回到 200 KB 以内；副作用是没有截图识别，只能手打或从拼多多/菜鸟页面抓。

## 怎么复现某一次构建

```bash
git checkout <commit>
cd android
gradle assembleRelease     # 需要 JDK 17 + Android SDK 34
```

或者把仓库 fork 到自己的 GitHub，push 后从 Actions 页下载 artifact（artifact 名 `PickupCode-<ver>-android-apk`，保留 90 天）。

## 下载 artifact 的脚本（没有 gh CLI 时）

```bash
# 1) 拿 token（需要本机 git 已保存 GitHub 凭据）
printf 'protocol=https\nhost=github.com\n\n' | git credential fill | grep '^password=' | cut -d= -f2

# 2) 列出最近的 artifact
curl -sS -H "Authorization: Bearer $TOK" \
  "https://api.github.com/repos/<owner>/<repo>/actions/artifacts?per_page=6"

# 3) 下载（注意会重定向到打包后的 zip）
curl -sS -L --fail -H "Authorization: Bearer $TOK" \
  -o out.zip "https://api.github.com/repos/<owner>/<repo>/actions/artifacts/<id>/zip"
```

Windows 上用 `curl.exe`，不要用 `Invoke-WebRequest`（大文件会卡在 0 字节）。
