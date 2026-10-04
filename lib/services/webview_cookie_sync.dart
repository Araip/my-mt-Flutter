import 'dart:io' show Cookie;

import 'package:cookie_jar/cookie_jar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as webview;

// ==================== Cookie 同步（Dio ⇄ WebView） ====================
//
// 人机验证必须在真实 WebView 里完成，所以两边的 Cookie 必须能互相搬运：
//   · Dio → WebView：打开验证页前注入登录态 cookie（否则验证页看到的是游客）
//   · WebView → Dio：验证通过后，服务端新下发的防护 cookie 只落在 WebView 里，
//     不回流的话 App 后续请求仍带旧值，表现为"浏览器过了、App 还是不行"
//
// 注意：**只注入登录相关的核心 cookie**（`{cookiepre}auth` / `saltkey`），
// 不要把整个 CookieJar 灌进 WebView。罐里可能存着服务端已判过期的防护
// cookie（如 `acw_tc`，`Max-Age` 只有 1 小时），灌回去会让挑战继续基于旧值
// 进行，形成"每次冷启动都要重新验证"的死锁。

/// 将登录 cookie 字符串同步到 WebView 原生 CookieManager。
///
/// 每次打开验证页 / 内置浏览器时调用，确保 WebView 携带与 API 请求相同的登录态。
/// cookieStr 格式：`name1=value1; name2=value2`
///
/// 注意：重复调用会覆盖同名 Cookie（domain / path / name 相同），不会产生重复条目。
Future<void> syncCookieStringToWebView(
  String? cookieStr,
  String baseUrl,
) async {
  final url = webview.WebUri(baseUrl);
  if (cookieStr == null || cookieStr.trim().isEmpty) {
    // 空 Cookie = 游客态：只清本站点，不动其他站点
    await clearCookiesForHost(baseUrl);
    return;
  }

  final host = Uri.parse(baseUrl).host;
  for (final pair in cookieStr.split(';')) {
    final trimmed = pair.trim();
    if (trimmed.isEmpty) continue;
    final eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    final name = trimmed.substring(0, eq);
    final value = trimmed.substring(eq + 1);
    await webview.CookieManager.instance().setCookie(
      url: url,
      name: name,
      value: value,
      domain: host, // 不使用前导点号，某些平台不支持带前导点号的 domain
      path: '/',
    );
  }
}

/// 清除指定站点的 WebView Cookie，**不影响其他站点**。
///
/// WebView 的 CookieManager 是平台级单例：`deleteAllCookies()` 会清掉所有
/// 站点的 Cookie；这里按 URL 逐条删除，只处理当前站点。
///
/// **不要用 `getAllCookies()`**：部分平台未实现（会直接抛
/// `UnimplementedError`）。改用 `getCookies(url:)`，它天然只返回该 URL
/// 适用的 Cookie，等于已经按站点隔离（某些平台上 `domain` 还可能为 null）。
///
/// 本函数**尽力而为、不抛异常**：它是 Cookie 注入前的清理步骤，失败只能记日志，
/// 绝不能连累后面的注入（否则浏览器会变成"未登录"）。
Future<void> clearCookiesForHost(String baseUrl) async {
  final host = Uri.tryParse(baseUrl)?.host ?? '';
  if (host.isEmpty) return;

  final manager = webview.CookieManager.instance();
  var scanned = 0;
  var deleted = 0;
  try {
    final cookies = await manager.getCookies(url: webview.WebUri(baseUrl));
    for (final cookie in cookies) {
      scanned++;
      // 一条 Cookie 要按多个 domain 写法各删一次，原因见 [_domainCandidates]
      for (final domain in _domainCandidates(cookie.domain, host)) {
        try {
          await manager.deleteCookie(
            url: webview.WebUri(baseUrl),
            name: cookie.name,
            path: cookie.path ?? '/',
            domain: domain,
          );
          deleted++;
        } catch (_) {
          // 单条删除失败不影响其它条目
        }
      }
    }
  } catch (e) {
    debugPrint('[CookieSync] 清理 $host 的 WebView cookie 失败: $e');
  }
  debugPrint(
    '[CookieSync] 清理 $host 的 WebView cookie：扫描 $scanned 条 / 删除调用 $deleted 次',
  );
}

/// 删除某条 Cookie 时应当尝试的 domain 候选值（按序执行）。
///
/// 平台 API 的坑（`flutter_inappwebview_android` 的 `MyCookieManager.java`）：
/// - `getCookies` **只在 WebView 支持 `GET_COOKIE_INFO` 时才回填 `domain`**，
///   否则一律为 null；
/// - 原生 `deleteCookie` 在 `domain == null` 时**不写 `Domain=` 属性**，
///   于是只会命中 host-only 的那条。
///
/// 两者叠加的结果：`Domain=.bbs.binmt.cc` 这种**域 Cookie 永远删不掉**，
/// 且删除接口照样返回成功（静默）。
///
/// 这里把三种存储形态都试一遍：
/// - `null`    → 不带 Domain，命中 host-only 形态
/// - `.{host}` → 命中最常见的 `Domain=.bbs.binmt.cc`
/// - 平台回填的 `cookie.domain`（可能是不带点号或父域写法）
///
/// 删除不存在的 Cookie 是无副作用的空操作，多试几次的代价可以接受。
List<String?> _domainCandidates(String? cookieDomain, String host) {
  final out = <String?>[null, '.$host'];
  final raw = (cookieDomain ?? '').trim();
  if (raw.isNotEmpty && !out.contains(raw)) out.add(raw);
  return out;
}

// ==================== WebView → Dio（反向同步） ====================

/// 把 WebView 的 Cookie 转换为可写入 [CookieJar] 的 `dart:io` Cookie。
///
/// - domain：统一成**前导点号**形式，与本 App 自身存 Cookie 的写法一致。
///   某些 Android 设备取不到 domain（依赖 `WebViewFeature.GET_COOKIE_INFO`），
///   此时回退到站点 host。
/// - 单条非法（`dart:io` 的 Cookie 按 RFC 6265 严格校验 name / value，值含
///   `,` 会抛 FormatException）时跳过该条，不让整次回流失败。
///
/// **一律不带 expires**（当作会话 cookie）：各端 `expiresDate` 的单位和含义
/// 都不可信（秒 / 毫秒混用，可能算出"现在 + N 毫秒"这种瞬时过期值），
/// 而唯一实际作用只是让 `cookie_jar` 在落盘时静默丢弃该条 —— 于是出现
/// "内存里有、磁盘上没有"，重启后又弹人机验证。
List<Cookie> toJarCookies(List<webview.Cookie> webCookies, Uri siteUri) {
  final result = <Cookie>[];
  for (final wc in webCookies) {
    if (wc.name.isEmpty) continue;
    try {
      final rawDomain = (wc.domain ?? '').trim();
      final domain = rawDomain.isEmpty
          ? '.${siteUri.host}'
          : (rawDomain.startsWith('.') ? rawDomain : '.$rawDomain');

      result.add(
        Cookie(wc.name, wc.value)
          ..domain = domain
          ..path = wc.path ?? '/'
          ..secure = wc.isSecure ?? (siteUri.scheme == 'https')
          ..httpOnly = wc.isHttpOnly ?? false,
      );
    } catch (e) {
      debugPrint('[CookieSync] 跳过非法 cookie "${wc.name}": $e');
    }
  }
  return result;
}

/// WebView → Dio：把 WebView 里属于 [baseUrl] 站点的 Cookie 写回 [jar]。
///
/// 场景：在验证页里过了人机验证、重新登录，或站点刷新了会话 Cookie ——
/// 这些 Cookie 只落在 WebView 的 CookieManager 里。
///
/// 用 `getCookies(url:)` 而不是 `getAllCookies()`：前者天然按 URL 过滤，不依赖
/// 某些平台上取不到的 `domain` 字段。
///
/// 返回**本次新出现的 Cookie**（"写回前罐里没有这个名字"），
/// 便于调用方记录日志、或补写到别处。
Future<List<Cookie>> syncWebViewCookiesToJar({
  required CookieJar jar,
  required String baseUrl,
}) async {
  final uri = Uri.tryParse(baseUrl);
  if (uri == null || uri.host.isEmpty) return const [];

  final webCookies = await webview.CookieManager.instance().getCookies(
    url: webview.WebUri(baseUrl),
  );
  if (webCookies.isEmpty) return const [];

  final cookies = toJarCookies(webCookies, uri);
  if (cookies.isEmpty) return const [];

  // 「罐里已有哪些名字」必须在写入前取快照：写入之后这些 cookie 也算已有，
  // 差集就永远为空了。
  Set<String>? existingNames;
  try {
    existingNames = (await jar.loadForRequest(uri)).map((c) => c.name).toSet();
  } catch (e) {
    debugPrint('[CookieSync] 读取 CookieJar 失败: $e');
  }

  // saveFromResponse 按 (domain, path, name) 覆盖同名条目，不会重复累积
  await jar.saveFromResponse(uri, cookies);

  final extras = existingNames == null
      ? const <Cookie>[]
      : cookies.where((c) => !existingNames!.contains(c.name)).toList();
  debugPrint(
    '[CookieSync] WebView → Dio 回流 ${uri.host}: ${cookies.length} 条'
    '${extras.isEmpty ? '' : '（新增 ${extras.length}: ${extras.map((c) => c.name).join(', ')}）'}',
  );
  return extras;
}
