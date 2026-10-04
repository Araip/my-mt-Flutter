import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../app_keys.dart';
import '../pages/verify_browser_page.dart';
import 'api_service.dart';
import 'interstitial_detector.dart';
import 'webview_cookie_sync.dart';

/// 全局人机验证守门器 —— "站点返回的不是论坛页"时的统一恢复入口。
///
/// 由 Dio 拦截器调用（见 `ApiService.interstitialHandler` 的注入与
/// `ApiService._recoverFromInterstitial` 的检测），流程：
/// 1. 弹出全屏验证浏览器（走根导航器，与当前所在页面无关）
/// 2. 用户在该浏览器里通过验证（纯 JS 挑战会自动通过，验证码 / 滑块需手动完成）
/// 3. **以"回流 cookie 后用相同 URL / UA 重发请求能拿到论坛页"为唯一判据**，
///    判定通过后自动关闭弹窗，Dio 拦截器随即重放原请求
///
/// 刻意不做厂商适配：判断依据是"这不是一个能用的论坛页"
/// （见 [looksLikeInterstitialPage]），因此对任何来源的人机验证都成立。
class VerificationGate {
  VerificationGate._();

  static final VerificationGate instance = VerificationGate._();

  /// 是否启用 —— 关闭后完全不介入（可绑定到设置项）
  bool Function() isEnabled = () => true;

  /// 当前账号的登录 cookie 串 —— 默认取 [ApiService.loginCookieString]。
  ///
  /// 验证页**只注入它**（而不是整个 CookieJar）：罐里可能存着服务端已判过期的
  /// 防护 cookie，灌进验证页会让挑战继续拿到旧值。
  String Function()? loginCookieString;

  /// 失败冷却：用户取消或超时后，短时间内不再弹窗，避免连续骚扰
  static const Duration _failureCooldown = Duration(seconds: 60);

  /// 单飞：验证进行中时，后续失败请求共用同一次结果
  Completer<bool>? _inFlight;

  DateTime _lastFailureAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 本次验证的探测上下文 —— 与失败请求保持一致
  String _probeUrl = '';
  String? _probeUserAgent;

  /// Dio 拦截器入口。返回 true 表示"已通过验证"。
  Future<bool> handle(RequestOptions options) async {
    if (!isEnabled()) return false;

    // 无 UI 上下文（启动早期的请求、后台任务）→ 无处可弹，直接失败。
    // 不能在这里挂起等待：那些场景没有用户，会把请求无限卡住。
    final nav = rootNavigatorKey.currentState;
    if (nav == null) {
      debugPrint('[Verify] 需要人机验证，但当前无可用界面，跳过弹窗');
      return false;
    }
    if (DateTime.now().difference(_lastFailureAt) < _failureCooldown) {
      debugPrint('[Verify] 人机验证处于冷却期，暂不弹窗');
      return false;
    }
    final existing = _inFlight;
    if (existing != null) return existing.future;

    final completer = Completer<bool>();
    _inFlight = completer;

    // 探测一律回到"触发拦截的那个地址"，并用同一个 UA —— 与失败请求同源，
    // 避免 cookie 与 UA 绑定导致"浏览器过了、API 还是不行"。
    _probeUrl = options.uri.toString();
    final ua = options.headers['User-Agent'];
    _probeUserAgent = ua == null ? null : ua.toString();

    var ok = false;
    try {
      debugPrint('[Verify] 弹出人机验证：$_probeUrl');
      final result = await nav.push<bool>(
        MaterialPageRoute<bool>(
          fullscreenDialog: true,
          builder: (_) => VerifyBrowserPage(
            url: _probeUrl,
            userAgent: _probeUserAgent ?? ApiService.mobileUserAgent,
            cookieString: _loginCookieString(),
            probe: _probePassed,
          ),
        ),
      );
      ok = result ?? false;
      debugPrint('[Verify] 人机验证结束：${ok ? '已通过' : '未通过'}');
    } catch (e) {
      debugPrint('[Verify] 人机验证流程异常: $e');
    } finally {
      if (!ok) _lastFailureAt = DateTime.now();
      _inFlight = null;
      if (!completer.isCompleted) completer.complete(ok);
    }
    return ok;
  }

  String _loginCookieString() {
    final custom = loginCookieString;
    if (custom != null) return custom();
    return ApiService.instance.loginCookieString;
  }

  /// 探测是否已通过。
  ///
  /// 这是**唯一权威判据**：不看 DOM、不看 cookie 变化，直接回流 WebView 的
  /// cookie 后用相同 URL / UA 重发一次请求 —— 拿到论坛页才算通过。
  /// 与拦截判定互为反面（同一个 [looksLikeInterstitialPage]），天然自洽。
  Future<bool> _probePassed() async {
    try {
      await syncWebViewCookiesToJar(
        jar: ApiService.instance.cookieJar,
        baseUrl: ApiService.baseUrl,
      );
    } catch (e) {
      debugPrint('[Verify] 探测前回流 cookie 失败: $e');
    }
    if (_probeUrl.isEmpty) return false;

    try {
      final resp = await ApiService.instance.dio.get<String>(
        _probeUrl,
        options: Options(
          // 明确按纯文本取回 HTML：探测只关心"是不是论坛页"
          responseType: ResponseType.plain,
          headers: {
            if (_probeUserAgent != null) 'User-Agent': _probeUserAgent,
          },
          // 标记已处理，避免探测自身再次触发弹窗
          extra: {kInterstitialHandledFlag: true},
        ),
      );
      if (resp.statusCode != 200) return false;
      final body = resp.data ?? '';
      if (body.isEmpty) return false;
      if (looksLikeInterstitialPage(body, resp.headers.value('content-type'))) {
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[Verify] 人机验证探测失败: $e');
      return false;
    }
  }
}
