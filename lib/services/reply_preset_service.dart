import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「回复可见」帖子的回复预设服务。
///
/// 只做两件事：
/// 1. 打开含隐藏内容的帖子时，把用户自定义的内容预填进输入框，按发送即可；
/// 2. 可选地自动发送（默认关闭，避免触发论坛发帖间隔限制或被判定为灌水）。
class ReplyPresetService extends ChangeNotifier {
  ReplyPresetService._();

  static final ReplyPresetService instance = ReplyPresetService._();

  static const _prefillEnabledKey = 'reply_preset_prefill_enabled';
  static const _autoSendEnabledKey = 'reply_preset_auto_send_enabled';
  static const _templateKey = 'reply_preset_template';
  static const _repliedTidsKey = 'reply_preset_replied_tids';

  /// 默认回复内容，用户可在「设置 → 回帖」里修改。
  static const defaultTemplate = '感谢分享，回复支持一下~';

  /// 最多记住多少个已回复过的帖子。
  static const _maxRememberedTids = 300;

  bool _prefillEnabled = true;
  bool _autoSendEnabled = false;
  String _template = defaultTemplate;
  List<String> _repliedTids = const [];
  bool _loaded = false;

  /// 打开「回复可见」帖时是否自动填入回复内容。
  bool get prefillEnabled => _prefillEnabled;

  /// 是否在填入后自动发送（默认关闭）。
  bool get autoSendEnabled => _autoSendEnabled;

  /// 用户自定义的回复内容（可能是空串）。
  String get template => _template;

  /// 实际使用的回复内容：自定义为空时回落到默认值。
  String get effectiveTemplate =>
      _template.trim().isEmpty ? defaultTemplate : _template;

  /// 已回复过的帖子数量。
  int get repliedCount => _repliedTids.length;

  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefillEnabled = prefs.getBool(_prefillEnabledKey) ?? true;
      _autoSendEnabled = prefs.getBool(_autoSendEnabledKey) ?? false;
      _template = prefs.getString(_templateKey) ?? defaultTemplate;
      _repliedTids = prefs.getStringList(_repliedTidsKey) ?? const [];
    } catch (_) {
      // 读取失败时保持默认值，不影响正常浏览。
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setPrefillEnabled(bool value) async {
    _prefillEnabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefillEnabledKey, value);
    } catch (_) {}
  }

  Future<void> setAutoSendEnabled(bool value) async {
    _autoSendEnabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_autoSendEnabledKey, value);
    } catch (_) {}
  }

  Future<void> setTemplate(String value) async {
    _template = value.trim();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_templateKey, _template);
    } catch (_) {}
  }

  /// 该帖子是否已经由本应用回复过（避免重复提示）。
  bool hasReplied(String tid) {
    if (tid.trim().isEmpty) return false;
    return _repliedTids.contains(tid);
  }

  /// 记录一个已回复的帖子，只保留最近 [_maxRememberedTids] 条。
  Future<void> markReplied(String tid) async {
    final key = tid.trim();
    if (key.isEmpty) return;
    final next = List<String>.from(_repliedTids)..remove(key);
    next.add(key);
    if (next.length > _maxRememberedTids) {
      next.removeRange(0, next.length - _maxRememberedTids);
    }
    _repliedTids = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_repliedTidsKey, next);
    } catch (_) {}
  }

  /// 清空「已回复过」记录，让这些帖子重新可以自动填入回复。
  Future<void> clearRepliedHistory() async {
    _repliedTids = const [];
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_repliedTidsKey);
    } catch (_) {}
  }
}
