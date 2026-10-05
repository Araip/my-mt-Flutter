import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/analytics_service.dart';
import '../services/feedback_service.dart';
import '../services/update_service.dart';
import '../../services/image_request_headers.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static const _avatarUrl = 'https://avatars.githubusercontent.com/u/187751705';
  static const _authorName = '我什么也不想要了';
  static const _qq = '615192041';
  static const _email = '615162041@qq.com';
  static const _forumName = 'Cynnie';
  static const _projectUrl = 'https://github.com/Araip/my-mt-Flutter';
  static const _projectLabel = 'github.com/Araip/my-mt-Flutter';
  static const _intro = 'MT论坛是一个基于 Flutter 开发的 MT 论坛（bbs.binmt.cc）'
      '第三方客户端。支持浏览版块、查看帖子与楼层、发帖回帖、图片查看、'
      '消息提醒、搜索、收藏与浏览历史等常用功能，并内置 BBCode 渲染、'
      '评论关键词过滤、字体与主题切换等本地增强能力。\n\n'
      '所有内容均来自 MT 论坛官方接口，客户端只做展示与交互优化，'
      '不修改、不存储你的账号与帖子数据。';

  late final Future<Map<String, dynamic>> _versionInfoFuture;

  final _contentController = TextEditingController();
  final _contactController = TextEditingController();
  bool _sending = false;
  AppStats? _appStats;
  bool _statsLoading = false;

  @override
  void initState() {
    super.initState();
    _versionInfoFuture = UpdateService.instance.getCurrentVersionInfo();
    _appStats = AnalyticsService.instance.latestStats;
    _loadStats();
  }

  Future<void> _loadStats() async {
    if (_statsLoading) return;
    setState(() => _statsLoading = true);
    final stats = await AnalyticsService.instance.fetchStats();
    if (!mounted) return;
    setState(() {
      _statsLoading = false;
      if (stats != null) _appStats = stats;
    });
  }

  @override
  void dispose() {
    _contentController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label 已复制'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 打开项目地址，失败时退化为复制到剪贴板。
  Future<void> _openProject() async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(_projectUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (opened || !mounted) return;
    await _copy('项目地址', _projectUrl);
  }

  Future<void> _submitFeedback() async {
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入反馈内容')),
      );
      return;
    }

    setState(() => _sending = true);
    final result = await FeedbackService.instance.submit(
      content: content,
      contact: _contactController.text,
    );

    if (!mounted) return;
    setState(() => _sending = false);

    if (result.success) {
      _contentController.clear();
      _contactController.clear();
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('关于'),
            pinned: true,
            centerTitle: true,
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  _buildAppHeader(theme, colors),
                  const SizedBox(height: 28),
                  const _SectionTitle(title: '软件介绍'),
                  const SizedBox(height: 10),
                  _buildIntroCard(theme, colors),
                  const SizedBox(height: 28),
                  const _SectionTitle(title: '作者信息'),
                  const SizedBox(height: 10),
                  _buildAuthorCard(theme, colors),
                  const SizedBox(height: 28),
                  const _SectionTitle(title: '项目地址'),
                  const SizedBox(height: 10),
                  _buildProjectCard(theme, colors),
                  const SizedBox(height: 28),
                  const _SectionTitle(title: '问题反馈'),
                  const SizedBox(height: 10),
                  _buildFeedbackCard(),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppHeader(ThemeData theme, ColorScheme colors) {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                colors.primary,
                colors.primary.withValues(alpha: 0.72),
              ],
            ),
          ),
          child: const Icon(
            Icons.forum_rounded,
            size: 40,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'MT论坛',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        FutureBuilder<Map<String, dynamic>>(
          future: _versionInfoFuture,
          builder: (context, snapshot) {
            final versionName =
                '${snapshot.data?['versionName'] ?? ''}'.trim();
            return Text(
              versionName.isEmpty ? 'v—' : 'v$versionName',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.outline,
              ),
            );
          },
        ),
        const SizedBox(height: 3),
        Text(
          'MT论坛第三方客户端',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.outline,
          ),
        ),
        const SizedBox(height: 12),
        _buildGlobalStats(theme, colors),
      ],
    );
  }

  Widget _buildGlobalStats(ThemeData theme, ColorScheme colors) {
    final stats = _appStats;
    if (stats == null) {
      return InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: _statsLoading ? null : _loadStats,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_statsLoading)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              else
                Icon(Icons.public_rounded, size: 16, color: colors.outline),
              const SizedBox(width: 6),
              Text(
                _statsLoading
                    ? '正在获取全网数据'
                    : AnalyticsService.instance.isConfigured
                        ? '全网数据暂不可用 · 点击重试'
                        : '匿名统计地址未配置',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colors.outline,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            _GlobalStatChip(
              icon: Icons.today_outlined,
              label: '今日启动',
              value: '${_formatCount(stats.todayLaunches)} 次',
            ),
            _GlobalStatChip(
              icon: Icons.rocket_launch_outlined,
              label: '全网启动',
              value: '${_formatCount(stats.totalLaunches)} 次',
            ),
            _GlobalStatChip(
              icon: Icons.install_mobile_outlined,
              label: '匿名安装',
              value: _formatCount(stats.uniqueInstalls),
            ),
            _GlobalStatChip(
              icon: Icons.calendar_today_outlined,
              label: '近7日活跃',
              value: _formatCount(stats.active7d),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          '匿名统计 · 不使用论坛 Cookie',
          style: theme.textTheme.labelSmall?.copyWith(
            color: colors.outline,
          ),
        ),
      ],
    );
  }

  String _formatCount(int value) {
    final text = value.toString();
    final out = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (i > 0 && (text.length - i) % 3 == 0) out.write(',');
      out.write(text[i]);
    }
    return out.toString();
  }

  /// 软件介绍卡片。
  Widget _buildIntroCard(ThemeData theme, ColorScheme colors) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_stories_outlined, size: 20, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'MT 论坛第三方客户端',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _intro,
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.62,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: const [
                _FeatureChip(label: '发帖回帖'),
                _FeatureChip(label: 'BBCode 渲染'),
                _FeatureChip(label: '评论过滤'),
                _FeatureChip(label: '字体与主题'),
                _FeatureChip(label: '无广告'),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '非官方客户端 · 与 MT 论坛官方无隶属关系',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 项目地址卡片：点击用外部浏览器打开，右侧按钮复制链接。
  Widget _buildProjectCard(ThemeData theme, ColorScheme colors) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: _openProject,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: colors.primaryContainer.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.code_rounded,
                      size: 20,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '项目仓库',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: colors.outline,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _projectLabel,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.open_in_new_rounded,
                    size: 18,
                    color: colors.outline,
                  ),
                ],
              ),
            ),
          ),
          Divider(
            height: 1,
            color: colors.outlineVariant.withValues(alpha: 0.65),
          ),
          InkWell(
            onTap: () => _copy('项目地址', _projectUrl),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 13, 18, 13),
              child: Row(
                children: [
                  Icon(
                    Icons.content_copy_rounded,
                    size: 18,
                    color: colors.outline,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '复制项目地址',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthorCard(ThemeData theme, ColorScheme colors) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
        child: Column(
          children: [
            Container(
              width: 104,
              height: 104,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.primaryContainer,
              ),
              child: ClipOval(
                child: Image.network(
                  _avatarUrl,
                  headers: ImageRequestHeaders.headersFor(_avatarUrl),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => ColoredBox(
                    color: colors.surfaceContainerHighest,
                    child: Icon(
                      Icons.person_rounded,
                      size: 48,
                      color: colors.primary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _authorName,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                color: colors.secondaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'MT论坛 · $_forumName',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colors.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Divider(color: colors.outlineVariant.withValues(alpha: 0.65)),
            _ContactRow(
              icon: Icons.chat_bubble_outline_rounded,
              label: 'QQ',
              value: _qq,
              onCopy: () => _copy('QQ', _qq),
            ),
            _ContactRow(
              icon: Icons.mail_outline_rounded,
              label: 'Email',
              value: _email,
              onCopy: () => _copy('邮箱', _email),
            ),
            _ContactRow(
              icon: Icons.forum_outlined,
              label: 'MT论坛',
              value: _forumName,
              onCopy: () => _copy('论坛用户名', _forumName),
            ),
            const SizedBox(height: 10),
            Divider(color: colors.outlineVariant.withValues(alpha: 0.65)),
            const SizedBox(height: 12),
            Text(
              '技能',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            const _SkillBar(label: 'C++', percent: 56),
            const SizedBox(height: 12),
            const _SkillBar(label: 'Shell', percent: 16),
            const SizedBox(height: 12),
            const _SkillBar(label: 'Python', percent: 7),
            const SizedBox(height: 12),
            const _SkillBar(label: 'Java', percent: 3),
          ],
        ),
      ),
    );
  }

  Widget _buildFeedbackCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _contentController,
              minLines: 1,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                labelText: '反馈内容',
                hintText: '描述遇到的问题或建议…',
                alignLabelWithHint: true,
                prefixIcon: Icon(Icons.feedback_outlined),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _contactController,
              decoration: const InputDecoration(
                labelText: '联系方式（可选）',
                hintText: 'QQ / 邮箱',
                prefixIcon: Icon(Icons.alternate_email_rounded),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _sending ? null : _submitFeedback,
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded, size: 18),
                label: Text(_sending ? '发送中…' : '提交反馈'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureChip extends StatelessWidget {
  final String label;
  const _FeatureChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _GlobalStatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _GlobalStatChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: colors.primary),
          const SizedBox(width: 5),
          Text(
            '$label $value',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onCopy;

  const _ContactRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onCopy,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colors.primaryContainer.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(11),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 19, color: colors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.outline,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      value,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.content_copy_rounded,
                size: 18,
                color: colors.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkillBar extends StatelessWidget {
  final String label;
  final int percent;

  const _SkillBar({required this.label, required this.percent});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '$percent%',
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: percent / 100,
            minHeight: 8,
            backgroundColor: colors.surfaceContainerHighest,
            color: colors.primary,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        title,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
