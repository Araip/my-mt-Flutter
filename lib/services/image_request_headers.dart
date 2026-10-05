import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

/// 图床（`icdn.binmt.cc` 等）在阿里云 ESA WAF 后面：不带 `acw_sc__v2` 通行
/// Cookie 去取图，服务器会 307 重定向回**它自己**，而 Dart 的 HttpClient /
/// CachedNetworkImage 都不保存 Cookie，于是每个图片请求都在「自己跳自己」的
/// 死循环里打转，界面上就全是破图。
///
/// 这个服务负责「先拿通行 Cookie，再交给图片组件」：
/// 1. [warmUp] 对给定地址所在的 host 做一次两段式预热（先收 Cookie，再自证）；
/// 2. [headersFor] 把已经拿到的 Cookie 镜像成图片组件的请求头。
///
/// 两条硬约束（都踩过坑，别再改回去）：
/// - **[headersFor] 绝不发网络请求**。它会在 `build()` 里被调用，一旦在这里
///   发请求，就变成「每次重建都打一轮网络」；论坛域名下的图片注定拿不到
///   Cookie，缓存不了，于是无限重试，把站点的 WAF 惹毛，连累正常接口请求
///   （表现就是首页/帖子列表空白）。所以预热只能由 [warmUp] 显式触发。
/// - **每个 host 每会话最多预热一次**，失败进冷却；且一次最多并行几个 host。
///   图片加载不出来可以忍，把主流程拖垮不行。
///
/// 全程吞异常，任何失败都只意味着「这次没拿到 Cookie」。
class ImageRequestHeaders {
  ImageRequestHeaders._();

  /// 站点对移动端模板下发的 UA，取 Cookie 时保持一致。
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36';

  static const String _referer = 'https://bbs.binmt.cc/';

  static const String _accept =
      'image/avif,image/webp,image/apng,image/*,*/*;q=0.8';

  static const Duration _requestTimeout = Duration(seconds: 6);

  /// 失败后多久内不再尝试同一个 host。
  static const Duration _failCooldown = Duration(minutes: 30);

  /// 单轮预热最多同时处理几个 host。
  static const int _maxParallelHosts = 2;

  /// 一次 [warmUp] 的总时间预算。
  ///
  /// 预热只是「锦上添花」，绝不能把调用方拖住：预算用完后剩下的 host 直接进
  /// 冷却，让 [warmUp] 立刻返回。即便如此，调用方也**不应该 await 它来挡渲染**。
  static const Duration _warmUpBudget = Duration(seconds: 12);

  /// **绝不去碰的 host**：论坛自身的域名。
  ///
  /// 它的 `acw_sc__v2` 通行 Cookie 是 ApiService 拿来跑接口的，属于「关键资源」；
  /// 图片服务在这里多发一次无 Cookie 的请求，就可能让 WAF 把整段通行证作废，
  /// 直接后果就是首页/帖子列表请求全部被挑战页挡掉（表现：列表空白）。
  /// 站点自身的静态图没有通行证时本来就取不到，保持原样即可，不要雪上加霜。
  static const Set<String> _neverWarmHosts = <String>{
    'bbs.binmt.cc',
    'www.binmt.cc',
    'binmt.cc',
  };

  static CookieJar? _jar;
  static Dio? _dio;

  /// host -> 可直接塞进图片请求头的 Cookie 串。
  static final Map<String, String> _cookieByHost = <String, String>{};

  /// host -> 冷却截止时间。
  static final Map<String, DateTime> _cooldownUntil = <String, DateTime>{};

  /// 正在预热的 host。
  static final Set<String> _warming = <String>{};

  /// 本会话已经试过的 host（无论成败都只试一次）。
  static final Set<String> _triedHosts = <String>{};

  static CookieJar get _cookieJar => _jar ??= CookieJar();

  static Dio get _client {
    final existing = _dio;
    if (existing != null) return existing;
    final client = Dio(
      BaseOptions(
        connectTimeout: _requestTimeout,
        receiveTimeout: _requestTimeout,
        sendTimeout: _requestTimeout,
        followRedirects: false,
        validateStatus: (int? code) => code != null && code < 500,
        headers: <String, dynamic>{
          'User-Agent': userAgent,
          'Referer': _referer,
          'Accept': _accept,
        },
      ),
    );
    client.interceptors.add(CookieManager(_cookieJar));
    _dio = client;
    return client;
  }

  /// 图片组件要用的请求头。**这里不会发任何网络请求。**
  ///
  /// 还没有预热到 Cookie 时只返回基础头（UA / Referer / Accept），
  /// 让图片组件自己去试；预热完成后的重建自然会带上 Cookie。
  static Map<String, String> headersFor(String? url) {
    final headers = <String, String>{
      'User-Agent': userAgent,
      'Referer': _referer,
      'Accept': _accept,
    };
    final host = _hostOf(url);
    if (host == null) return headers;
    if (_neverWarmHosts.contains(host)) return headers;
    final cookie = _cookieByHost[host];
    if (cookie != null && cookie.isNotEmpty) {
      headers['Cookie'] = cookie;
    }
    return headers;
  }

  /// 预热一批图片地址（按 host 去重）。永不抛异常。
  ///
  /// 应该在数据加载完成后**显式调用一次**（例如帖子详情解析出配图之后），
  /// 不要放在 `build()` 里。
  static Future<void> warmUp(Iterable<String?> urls) async {
    final firstUrlByHost = <String, String>{};
    for (final url in urls) {
      if (url == null) continue;
      final host = _hostOf(url);
      if (host == null) continue;
      if (_neverWarmHosts.contains(host)) continue;
      firstUrlByHost.putIfAbsent(host, () => url.trim());
    }
    if (firstUrlByHost.isEmpty) return;

    final now = DateTime.now();
    final todo = <String>[];
    for (final host in firstUrlByHost.keys) {
      if (_cookieByHost.containsKey(host)) continue;
      if (_triedHosts.contains(host)) continue;
      final until = _cooldownUntil[host];
      if (until != null && now.isBefore(until)) continue;
      if (_warming.contains(host)) continue;
      todo.add(host);
    }
    if (todo.isEmpty) return;

    final deadline = DateTime.now().add(_warmUpBudget);
    for (var i = 0; i < todo.length; i += _maxParallelHosts) {
      if (!DateTime.now().isBefore(deadline)) {
        // 预算用尽：剩下的 host 进冷却，立刻返回，别让调用方继续等。
        for (final host in todo.sublist(i)) {
          _cooldownUntil[host] = DateTime.now().add(_failCooldown);
        }
        return;
      }
      final end = i + _maxParallelHosts < todo.length
          ? i + _maxParallelHosts
          : todo.length;
      await Future.wait(
        todo.sublist(i, end).map(
              (String host) => _warmUpHost(host, firstUrlByHost[host]),
            ),
      );
    }
  }

  static Future<void> _warmUpHost(String host, String? url) async {
    if (url == null || url.isEmpty) return;
    if (!_warming.add(host)) return;
    _triedHosts.add(host);
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return;

      // 第一发：不跟随跳转，只为收下 WAF 随 307 一起下发的 Cookie。
      await _client.getUri<String>(
        uri,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
        ),
      );

      final cookies = await _cookieJar.loadForRequest(uri);
      final cookieHeader = cookies
          .map((Cookie c) => '${c.name}=${c.value}')
          .join('; ');
      if (cookieHeader.isEmpty) {
        // 没有下发 Cookie：这个 host 不需要通行证，或者策略变了。
        // 不缓存，但进冷却，别反复打。
        _cooldownUntil[host] = DateTime.now().add(_failCooldown);
        return;
      }

      // 自证：带上 Cookie 再取一次，确认真能拿到图，而不是又一张挑战页。
      final probe = await _client.getUri<List<int>>(
        uri,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          headers: <String, dynamic>{'Cookie': cookieHeader},
        ),
      );
      final body = probe.data;
      final contentType =
          probe.headers.value('content-type')?.toLowerCase() ?? '';
      final looksLikeHtml = contentType.contains('text/html');
      if (probe.statusCode == 200 &&
          body != null &&
          body.isNotEmpty &&
          !looksLikeHtml) {
        _cookieByHost[host] = cookieHeader;
        _cooldownUntil.remove(host);
      } else {
        _cooldownUntil[host] = DateTime.now().add(_failCooldown);
      }
    } catch (_) {
      // 拿不到就算了：图片显示不出来是可接受的降级。
      _cooldownUntil[host] = DateTime.now().add(_failCooldown);
    } finally {
      _warming.remove(host);
    }
  }

  static String? _hostOf(String? url) {
    if (url == null) return null;
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    final scheme = uri.scheme;
    if (scheme != 'http' && scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    return uri.host;
  }

  /// 退出登录等场景清空缓存。
  static void reset() {
    _cookieByHost.clear();
    _cooldownUntil.clear();
    _warming.clear();
    _triedHosts.clear();
  }
}
