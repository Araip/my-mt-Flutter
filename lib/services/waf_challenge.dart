import 'dart:convert';

/// 阿里云 ESA / WAF 的 `acw_sc__v2` JS 挑战求解器。
///
/// ## 背景
///
/// 站点（ESA 前置）在判定「这个请求可疑」时，不返回论坛页，而是返回一个
/// 4KB 左右的脚本挑战页：
///
/// ```html
/// <html><script>var arg1='BBFF35568B13AA5F077B2732DC3DC33B13A66C16';
/// (function(a,c){ ... })(a0i,0x760bf), ...
/// </script></html>
/// ```
///
/// 真实浏览器里这段脚本会算出 `acw_sc__v2` 写进 Cookie 再重载页面，于是
/// 「第 1 次被拦、第 2 次就通过」。挑战页本身**不需要任何人工操作**。
///
/// ## 为什么要在 Dart 里复刻
///
/// 开 WebView 让 JS 自己去算当然也行，但那意味着：弹窗、等加载、指不定还有
/// 「验证完了却不返回」的坑，而且**后台请求根本没有界面可弹**。
/// 而这段脚本的核心运算只是两个静态变换（打乱 + 异或），
/// 完全可以离线复刻 —— 于是挑战变成一次静默的本地计算：
/// 不需要 JS 引擎、不需要用户、不需要界面。
///
/// ## 算法
///
/// ```text
/// acw_sc__v2 = hexXor(unsbox(arg1), "3000176000856006061501533003690027800375")
/// ```
///
/// - `unsbox`：按固定的 40 位下标表把 `arg1` 重新排列
/// - `hexXor`：把两个 hex 串按字节异或
///
/// `arg1` 每次响应都不同（服务端每次生成），所以 `acw_sc__v2` 也每次都不同；
/// 但只要 Cookie 正确，服务端就不再发挑战（与 `acw_tc` 一起约 1 小时有效）。
///
/// **注意**：这里只负责「算出候选值」，算得对不对由调用方用「重发一次看还是
/// 不是挑战页」来验证 —— 阿里云有多个变体，不能假设一次就中。
/// 这样即使以后换了算法，最坏也只是退回到人工验证，不会误判成「已通过」。
class WafChallenge {
  WafChallenge._();

  /// `var arg1='<40 位 hex>'` —— 挑战页里唯一需要提取的动态值。
  ///
  /// 宽松匹配（允许空格、可有可无的分号、大小写皆可），
  /// 因为混淆器可能把它写成 `var arg1 = "…";` 之类的形态。
  static final RegExp _arg1Pattern = RegExp(
    r'''arg1\s*=\s*['"]([0-9A-Fa-f]{20,})['"]''',
  );

  /// 异或用的固定密钥（各站点通用，来自混淆脚本中未混淆的字面量）。
  static const String _xorKey = '3000176000856006061501533003690027800375';

  /// `unsbox` 的下标表：输出第 n 个字符 = 输入的第 `_unescapeKey[n]` 个字符
  /// （原文是 1-based，取值时减 1）。
  static const List<int> _unescapeKey = <int>[
    0xf, 0x23, 0x1d, 0x18, 0x21, 0x10, 0x1, 0x26, 0xa, 0x9, //
    0x13, 0x1f, 0x28, 0x1b, 0x16, 0x17, 0x19, 0xd, 0x6, 0xb, //
    0x27, 0x12, 0x14, 0x8, 0xe, 0x15, 0x20, 0x1a, 0x2, 0x1e, //
    0x7, 0x4, 0x11, 0x5, 0x3, 0x1c, 0x22, 0x25, 0xc, 0x24,
  ];

  /// 从响应体里取出 `arg1`；不是挑战页则返回 null。
  static String? extractArg1(String body) {
    if (body.isEmpty || body.length > 64 * 1024) return null;
    if (!body.contains('arg1')) return null;
    return _arg1Pattern.firstMatch(body)?.group(1);
  }

  /// 这个响应是不是 `acw_sc__v2` 挑战页。
  ///
  /// 判据刻意很窄（必须能提取出 `arg1` 且能算出结果），
  /// 避免把普通页面误判成挑战页。
  static bool isChallenge(String body) => extractArg1(body) != null;

  /// 由 `arg1` 算出 `acw_sc__v2`；算不出来（长度/字符不合法）返回 null。
  static String? solve(String arg1) {
    if (arg1.isEmpty) return null;
    // 必须是偶数长度的 hex，否则异或无法按字节对齐
    if (arg1.length.isOdd) return null;
    if (arg1.length < _unescapeKey.length) return null;
    if (!RegExp(r'^[0-9A-Fa-f]+$').hasMatch(arg1)) return null;

    final shuffled = _unsbox(arg1);
    return _hexXor(shuffled, _xorKey);
  }

  /// 便捷入口：直接从响应体算 `acw_sc__v2`，不是挑战页则返回 null。
  static String? solveFromBody(String body) {
    final arg1 = extractArg1(body);
    if (arg1 == null) return null;
    return solve(arg1);
  }

  /// `unsbox`：按固定下标表重排字符串。
  static String _unsbox(String arg) {
    final out = StringBuffer();
    for (final index in _unescapeKey) {
      final i = index - 1;
      if (i < 0 || i >= arg.length) return '';
      out.write(arg[i]);
    }
    return out.toString();
  }

  /// 两个等长 hex 串按字节异或。
  static String _hexXor(String a, String b) {
    final n = a.length < b.length ? a.length : b.length;
    final out = StringBuffer();
    for (var i = 0; i + 1 < n; i += 2) {
      final x = int.tryParse(a.substring(i, i + 2), radix: 16);
      final y = int.tryParse(b.substring(i, i + 2), radix: 16);
      if (x == null || y == null) return '';
      out.write((x ^ y).toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  /// 仅用于自检 / 日志：`utf8` 长度，避免把二进制塞进日志。
  static int byteLength(String s) => utf8.encode(s).length;
}
