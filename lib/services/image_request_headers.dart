import 'dart:async';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

/// 帖子/头像等站外图片的请求头，以及图床 WAF 通行 Cookie 的统一入口。
///
/// ## 为什么要这个东西
///
/// 站点把帖子图片放到了新图床 `icdn.binmt.cc`，该域名挂在阿里云 ESA WAF
/// 后面。不带通行 Cookie 去取图，服务器会应答：
///
/// ```text
/// HTTP/2 307
/// server: ESA
/// x-tengine-error: denied by http_custom
/// set-cookie: acw_sc__v2=...;path=/;HttpOnly;Max-Age=1800
/// location: /2509/68d26bef5fdb3.jpg      <- 重定向回它自己
/// ```
///
/// 客户端会在这个「自己跳自己」的重定向里打转，最后抛错，界面上表现为
/// **所有帖子图片都加载失败**（只剩 errorWidget 的破图占位）。
///
/// 和 `bbs.binmt.cc` 的 JS 挑战不同，图床这道门**不需要执行 JS**：WAF 在
/// 第一次响应里就把 `acw_sc__v2` 直接 `Set-Cookie` 下来了。真正的坑在于
/// Dart 的 `HttpClient` 和 `CachedNetworkImage` 都**不保存 Cookie**，所以
/// 每次取图都是「裸奔」，必然打转。
///
/// ## 做法
///
/// 用一个独立的 Dio + CookieJar 给每个图片域名做一次「预热」：
///
/// 1. 第一发 `followRedirects: false`，只为把 WAF 下发的 Cookie 存进 jar；
/// 2. 第二发带上 jar 里的 Cookie，正常取到图片（顺带确认通路可用）；
/// 3. 把该域名的 Cookie 拼成字符串镜像出来，交给图片组件的 `httpHeaders`。
///
/// `bbs.binmt.cc` 这类需要 JS 挑战的域名不归这里管（见 `waf_challenge.dart`），
/// 预热失败也不影响主流程。
class ImageRequestHeaders {
  ImageRequestHeaders._();

  /// 与 `ApiService.mobileUserAgent` 保持一致。
  ///
  /// WAF 有可能把通行 Cookie 和 UA 绑定，两边 UA 不一致会出现
  /// 「预热拿到的 Cookie 交给图片组件就失效」。
  static const String userAgent = 'Mozilla/5.0 (Linux; Android 16) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/150.0.0.0 Mobile Safari/537.36';

  static const String referer = 'https://bbs.binmt.cc/';

  static const String _accept =
      'image/avif,image/webp,image/apng,image/*,*/*;q=0.8';

  /// 单个域名的预热上限，避免拖慢帖子首屏。
  static const Duration _warmUpTimeout = Duration(seconds: 8);

  /// host -> 拼接好的 Cookie 头。
  static final Map<String, String> _cookieByHost = <String, String>{};

  /// 正在预热的 host，防止并发重复请求。
  static final Set<String> _warming = <String>{};

  static CookieJar? _jar;
  static Dio? _dio;

  static CookieJar get _cookieJar => _jar ??= CookieJar();

  static Dio get _client {
    final cached = _dio;
    if (cached != null) return cached;
    final dio = Dio(
      BaseOptions(
        headers: <String, String>{
          'User-Agent': userAgent,
          'Referer': referer,
          'Accept': _accept,
        },
        responseType: ResponseType.bytes,
        // 预热只关心 Cookie，4xx 也当成「有结果」处理，别抛异常。
        validateStatus: (int? status) => status != null && status < 500,
      ),
    );
    dio.interceptors.add(CookieManager(_cookieJar));
    _dio = dio;
    return dio;
  }

  /// 图片组件要用的请求头。
  ///
  /// 已预热的域名会带上通行 Cookie；没预热的会顺手在后台补一次，
  /// 这样即使调用方漏了 [warmUp]，等组件下次重建也能恢复。
  static Map<String, String> headersFor(String url) {
    final headers = <String, String>{
      'User-Agent': userAgent,
      'Referer': referer,
      'Accept': _accept,
    };
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return headers;
    final cookie = _cookieByHost[uri.host];
    if (cookie != null && cookie.isNotEmpty) {
      headers['Cookie'] = cookie;
    } else {
      unawaited(warmUp(<String>[url]));
    }
    return headers;
  }

  /// 预热一批图片地址所属的域名（同一域名只做一次）。
  ///
  /// 永不抛异常：预热只是优化，失败也应该让页面照常显示。
  static Future<void> warmUp(Iterable<String> urls) async {
    final hosts = <String, Uri>{};
    for (final raw in urls) {
      if (raw.isEmpty) continue;
      final uri = Uri.tryParse(raw);
      if (uri == null) continue;
      if (uri.scheme != 'http' && uri.scheme != 'https') continue;
      hosts.putIfAbsent(uri.host, () => uri);
    }
    if (hosts.isEmpty) return;
    await Future.wait<void>(
      hosts.values.map((Uri uri) async {
        try {
          await _warmUpHost(uri).timeout(_warmUpTimeout);
        } catch (_) {
          // 预热失败不影响主流程。
        }
      }),
    );
  }

  /// 清空已缓存的通行 Cookie（账号切换 / 退出登录时调用）。
  static void reset() {
    _cookieByHost.clear();
    _warming.clear();
  }

  static Future<void> _warmUpHost(Uri uri) async {
    final host = uri.host;
    if (_cookieByHost.containsKey(host)) return;
    if (!_warming.add(host)) return;
    try {
      final target = uri.toString();
      final dio = _client;

      // 第一发：不跟随重定向，只为收下 WAF 的 Set-Cookie。
      try {
        await dio.get<List<int>>(
          target,
          options: Options(followRedirects: false),
        );
      } catch (_) {
        // 忽略：Cookie 挂在 3xx 响应上，这里不关心状态码。
      }

      // 第二发：CookieManager 会把上一步存下的 Cookie 带上。
      try {
        await dio.get<List<int>>(target);
      } catch (_) {
        // 图片本身取不取得到不影响 Cookie 镜像。
      }

      final cookies = await _cookieJar.loadForRequest(uri);
      if (cookies.isEmpty) return;
      _cookieByHost[host] =
          cookies.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (_) {
      // 预热失败不抛出。
    } finally {
      _warming.remove(host);
    }
  }
}
