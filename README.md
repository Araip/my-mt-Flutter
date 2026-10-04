# MT论坛 Flutter 客户端

MT管理器论坛 (bbs.binmt.cc) 第三方客户端，基于 Flutter + Material Design 3。

## 快速开始

```bash
flutter pub get
flutter run
```

## 编译 APK

```bash
flutter build apk --release
```

## 自动打包（GitHub Actions）

推任意分支、推 `v*` 标签，或在 Actions 页面手动 `Run workflow`，都会自动构建 arm64 release APK，
产物在对应运行记录的 **Artifacts** 区（名为 `mtforum-<版本号>`）；推 `v*` 标签还会自动发 Release。

### 签名配置（必需，否则用 debug 密钥签名）

`key.properties` 与 keystore 都不入库（见 `.gitignore`），CI 上由 workflow 从仓库 Secret 还原。
在仓库 **Settings → Secrets and variables → Actions** 添加以下 4 个 Secret：

| Secret 名 | 值 |
| --- | --- |
| `KEYSTORE_BASE64` | keystore 文件的 base64 文本 |
| `KEYSTORE_PASSWORD` | keystore 密码（storePassword） |
| `KEY_ALIAS` | 密钥别名（keyAlias） |
| `KEY_PASSWORD` | 密钥密码（keyPassword） |

生成 `KEYSTORE_BASE64`（在 AndroidIDE 终端执行，`-w0` 很关键，不能有换行）：

```bash
base64 -w0 /root/mtforum-release.keystore > /sdcard/keystore-base64.txt
```

然后打开 `/sdcard/keystore-base64.txt` 复制全文，粘贴为 Secret 的值。

未配置 `KEYSTORE_BASE64` 时构建**不会失败**，会回退用 debug 密钥签名——
包能装、能测，但**无法覆盖已发布版本**，正式发版务必配好签名。

## 文档

- [开发进度](开发进度.md) - 功能清单、已知问题、代码结构
- [接口文档](binmt_api_doc.md) - 34个论坛API接口完整说明

## 人机验证（人机验证 / 防火墙拦截页）自动恢复

站点偶尔会对请求返回人机验证页（阿里云 ESA 的 JS 挑战 / 滑块验证码 / WAF 拦截页），
而不是论坛页面。这类响应由一个全局守门器自动兜住，无需在每个页面里写适配：

| 文件 | 作用 |
| --- | --- |
| `lib/services/interstitial_detector.dart` | `looksLikeInterstitialPage()`：只判断"这是不是一个能用的论坛页"，不做厂商适配 |
| `lib/services/webview_cookie_sync.dart` | Dio ⇄ WebView 的 Cookie 互搬（注入登录态 / 回流防护 cookie） |
| `lib/services/verification_gate.dart` | `VerificationGate`：弹出验证浏览器 → 探测是否通过 → 交给 Dio 重放 |
| `lib/pages/verify_browser_page.dart` | 全屏验证 WebView（纯 JS 挑战自动通过，验证码需手动完成） |
| `lib/app_keys.dart` | `rootNavigatorKey`，让守门器能在任意位置弹全屏页 |
| `lib/services/api_service.dart` | 拦截器检测 + `_recoverFromInterstitial()`；导出 `cookieJar` / `dio` / `loginCookieString` |
| `lib/main.dart` | 挂 `navigatorKey`，注入 `ApiService.instance.interstitialHandler` |

流程：Dio 响应命中"非论坛页" → 弹出验证浏览器（用**触发拦截的那个 URL 和同一个 UA**）
→ 回流 WebView cookie → 用相同 URL / UA 重发一次，拿到论坛页才算通过 → 自动关闭并重放原请求。
仅 GET 自动重放，写操作（发帖 / 评论）验证通过后由用户手动重试，避免重复提交。

需要 `flutter pub get`（新增 `flutter_inappwebview: ^6.1.5`）。
临时关闭：`VerificationGate.instance.isEnabled = () => false;`

## 技术栈

- Flutter 3.27.0 + Dart 3.6.0
- Material Design 3 (ColorScheme.fromSeed)
- Dio (HTTP) + Cookie管理
- html (HTML解析)
- photo_view (图片缩放)
- cached_network_image (图片缓存)
