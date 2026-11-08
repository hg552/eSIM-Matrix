import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../adapter/composite_adapter.dart';
import '../../pages/app_logs_page.dart';
import '../../services/diagnostics_service.dart';
import '../../settings/app_settings.dart';
import '../../theme/app_theme.dart';
import '../glass/glass_surface.dart';
import '../common/loading_spinner.dart';

/// Embedded diagnostics view displayed on empty reader or card detection screens.
///
/// Gives the user and developer immediate visibility into OMAPI, SEService,
/// system features, connector switches, and discovery errors with one-click copy.
class ReaderDiagnosticsView extends StatefulWidget {
  const ReaderDiagnosticsView({
    super.key,
    this.initiallyExpanded = true,
    this.onRescanRequested,
  });

  final bool initiallyExpanded;
  final Future<void> Function()? onRescanRequested;

  @override
  State<ReaderDiagnosticsView> createState() => _ReaderDiagnosticsViewState();
}

class _ReaderDiagnosticsViewState extends State<ReaderDiagnosticsView> {
  DiagnosticsSnapshot? _snapshot;
  bool _loading = true;
  String? _error;
  bool _showFullReport = false;

  @override
  void initState() {
    super.initState();
    _loadDiagnostics();
  }

  Future<void> _loadDiagnostics() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snap = await DiagnosticsService.collect(
        adapter: CompositeAdapter(),
        maxLogLines: 60,
      );
      if (mounted) {
        setState(() {
          _snapshot = snap;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _handleRescan() async {
    if (widget.onRescanRequested != null) {
      await widget.onRescanRequested!();
    } else {
      try {
        await CompositeAdapter().listReaders(force: true);
      } catch (_) {}
    }
    await _loadDiagnostics();
  }

  void _copyReport(BuildContext context) {
    final text = _snapshot?.reportText;
    if (text == null || text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          '✅ 完整诊断报告已复制到剪贴板！可直接粘贴发送给开发者做排查。',
        ),
        duration: Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isGlass = AppSettings().enableGlassUi;
    final glassBg = isDark
        ? const Color(0xFF141B2D).withValues(alpha: 0.65)
        : Colors.white.withValues(alpha: 0.72);

    Widget content = Container(
      decoration: BoxDecoration(
        color: isGlass
            ? glassBg
            : (isDark ? const Color(0xFF1E222B) : const Color(0xFFF4F6F9)),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isGlass
              ? Colors.white.withValues(alpha: 0.18)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.troubleshoot_rounded,
                    size: 22,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '硬件与接口诊断报告',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'v1.3',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '未检测到读卡器时的底层状态排查',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.onSurfaceSubtle(context),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_loading)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: LoadingSpinner(size: 20),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    tooltip: '刷新诊断',
                    onPressed: _handleRescan,
                  ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Content body
          if (_loading && _snapshot == null)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Column(
                  children: [
                    LoadingSpinner(size: 28),
                    SizedBox(height: 12),
                    Text(
                      '正在采集底层 Telephony / OMAPI / 系统特性诊断数据...',
                      style: TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            )
          else if (_error != null && _snapshot == null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '采集诊断失败: $_error',
                style: const TextStyle(color: Colors.red),
              ),
            )
          else if (_snapshot != null) ...[
            // Key findings (hints)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ..._snapshot!.hints.map((h) => _buildHintCard(context, h)),
                  if (_snapshot!.hints.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.check_circle_outline, color: Colors.green, size: 20),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '各硬件接口配置正常。如需外接读卡器请检查物理连接。',
                              style: TextStyle(fontSize: 13, color: Colors.green),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),

            // Monospace code box
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: _showFullReport ? 450 : 200,
                ),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF13161C) : const Color(0xFF21252B),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                padding: const EdgeInsets.all(12),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _snapshot!.reportText,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.45,
                      color: Color(0xFFDCDFE4),
                    ),
                  ),
                ),
              ),
            ),

            // Expand/collapse text toggle
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    '已脱敏 (ICCID/EID 已隐藏)',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppTheme.onSurfaceSubtle(context),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() => _showFullReport = !_showFullReport),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    ),
                    child: Text(_showFullReport ? '收起报告' : '展开完整报告'),
                  ),
                ],
              ),
            ),

            // Bottom Actions Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('一键复制完整诊断报告'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () => _copyReport(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.article_outlined, size: 18),
                    label: const Text('控制台日志'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const AppLogsPage(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 16),
      child: isGlass
          ? GlassSurface(
              radius: 18,
              child: content,
            )
          : content,
    );
  }

  Widget _buildHintCard(BuildContext context, DiagnosticHint hint) {
    final color = switch (hint.severity) {
      DiagnosticSeverity.error => Colors.red,
      DiagnosticSeverity.warning => Colors.orange,
      DiagnosticSeverity.info => Colors.blue,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hint.severityEmoji,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${hint.titleZh} (${hint.titleEn})',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: color.shade800,
                  ),
                ),
              ),
            ],
          ),
          if (hint.detailZh != null || hint.detailEn != null) ...[
            const SizedBox(height: 6),
            Text(
              hint.detailZh ?? hint.detailEn!,
              style: const TextStyle(fontSize: 12, height: 1.4),
            ),
          ],
          if (hint.actionZh != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '👉 解决建议: ${hint.actionZh}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color.shade900,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
