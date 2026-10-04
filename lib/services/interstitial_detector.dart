// 通用拦截页检测（人机验证 / 防火墙，与厂商无关）。
//
// 判定思路：真实 Discuz 页面必然有 `<body>`，且必然带论坛骨架痕迹；
// 而人机验证 / WAF 的拦截页通常只是几 KB 的脚本挑战或跳转桩。
// 所以这里只判断"结构"，**刻意不做厂商特征匹配**
// （不认 `acw_sc__v2`、不认具体验证码厂商）——
// 任何新出现的人机验证页，只要它同样"不是一个能用的论坛页"，就会被命中，
// 无需逐家适配。
//
// 实测样本（阿里云 ESA JS 挑战页）：`<html><script>var arg1='…'`，
// 4321 字节、无 `<body>`、无 DOCTYPE —— 命中。
// 实测样本（真实帖子页）：含 `<body>`、`Discuz! X3.4`、`formhash` —— 不命中。

/// 请求级标记：本次请求已由拦截页处理器处理过，避免递归触发。
const String kInterstitialHandledFlag = 'mtforumInterstitialHandled';

/// 判定上限：真实 Discuz 页面远大于此（实测帖子页 ~160KB），
/// 而验证 / 跳转桩通常在几 KB 量级。
const int _kInterstitialMaxBodyLength = 64 * 1024;

/// 判断响应是否"不是一个能用的论坛页"——通用拦截页（人机验证 / 防火墙 / WAF）。
///
/// 两道门槛用于排除误判：
/// - `content-type` 必须含 `text/html`（JSON / 图片等接口天然排除）
/// - 必须含 `<html`（Discuz 的 `inajax=1` 响应是 XML/CDATA 包装，天然排除）
bool looksLikeInterstitialPage(String body, String? contentType) {
  if (body.isEmpty) return false;
  if (!(contentType ?? '').toLowerCase().contains('text/html')) return false;
  if (body.length > _kInterstitialMaxBodyLength) return false;

  final lower = body.toLowerCase();
  if (!lower.contains('<html')) return false;

  // 有 <body>：可能是"带 body 的验证页"——仅当完全没有论坛痕迹且正文极少时才判定
  if (lower.contains('<body')) {
    if (_hasDiscuzSkeleton(lower)) return false;
    return _visibleTextLength(body) < 256;
  }

  // 无 <body> 的完整文档：脚本挑战 / 跳转桩（当前阿里云 WAF 即此类）
  return lower.contains('<script') || lower.contains('<meta');
}

/// 论坛页骨架痕迹——任一命中即认为"这是论坛页"，不是拦截页。
///
/// 这些是 Discuz 的全局骨架（跨模板、跨页面稳定），比 `#postlist` 之类的
/// 页面级选择器更通用：列表页、空间页、消息页同样命中。
///
/// 注意：骨架判定必须"宁可判成论坛页"——把正常页误判成拦截页会平白弹出
/// 浏览器（用户可感知的打扰），而漏判只是回到既有的"页面解析失败"提示。
bool _hasDiscuzSkeleton(String lowerBody) {
  if (lowerBody.contains('discuz') ||
      lowerBody.contains('formhash') ||
      lowerBody.contains('comiis')) {
    return true;
  }
  // 布局骨架 id：`#ct` / `#hd` / `#ft`，以及页面骨架 id
  return RegExp(
    r'''id\s*=\s*["']?(ct|hd|ft|postlist|thread_subject)\b''',
  ).hasMatch(lowerBody);
}

/// 粗略统计可见文本长度（剔除 script/style 与标签），用于判断"内容极少"。
int _visibleTextLength(String html) {
  final text = html
      .replaceAll(
        RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
        ' ',
      )
      .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ');
  return text.trim().length;
}
