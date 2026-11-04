import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/shizuku_bundle.dart';
import '../../theme/app_theme.dart';

/// Shizuku state plus the one action that is useful right now.
///
/// QRTR and SE HAL both go through Shizuku, and on a phone without root its
/// server has to be started from a computer after every reboot. Users lose that
/// step, so this row states where they are and shows the exact command.
class ShizukuStatusTile extends StatefulWidget {
  const ShizukuStatusTile({super.key});

  @override
  State<ShizukuStatusTile> createState() => _ShizukuStatusTileState();
}

class _ShizukuStatusTileState extends State<ShizukuStatusTile>
    with WidgetsBindingObserver {
  ShizukuBundleStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the installer or from Shizuku's own screen.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final status = await ShizukuBundle.status();
      if (mounted) setState(() => _status = status);
    } catch (_) {
      if (mounted) setState(() => _status = ShizukuBundleStatus.unknown);
    }
  }

  Future<void> _act() async {
    final status = _status;
    if (status == null || _busy) return;

    if (status.needsInstall) {
      setState(() => _busy = true);
      try {
        final outcome = await ShizukuBundle.install();
        if (!mounted) return;
        if (outcome == 'settings_opened') {
          _toast('请先允许本应用「安装未知应用」，再回来点一次安装');
        } else if (outcome == 'installer_opened') {
          _toast('下载完成，已打开安装程序，请确认安装 Shizuku');
        } else if (outcome == 'already_installed') {
          _toast('Shizuku 已安装');
        }
      } catch (e) {
        _toast('安装失败: $e');
      } finally {
        if (mounted) setState(() => _busy = false);
        await _refresh();
      }
      return;
    }

    if (status.needsStart) {
      await _showStartGuide(status);
      return;
    }

    await ShizukuBundle.launch();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
    );
  }

  Future<void> _showStartGuide(ShizukuBundleStatus status) async {
    final command = status.starterCommand;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启动 Shizuku'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Shizuku 已安装，但服务端没有运行。手机未 Root 时，'
              '每次重启后都需要从电脑执行一次下面的命令：',
              style: TextStyle(height: 1.5),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                command ?? '（未找到启动器，请在 Shizuku 应用内按提示启动）',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '1. 手机开启「USB 调试」并连接电脑\n'
              '2. 在电脑终端粘贴上面的命令执行\n'
              '3. 回到这里下拉刷新',
              style: TextStyle(height: 1.6),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          if (command != null)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: command));
                if (context.mounted) Navigator.pop(context);
                _toast('启动命令已复制');
              },
              child: const Text('复制命令'),
            ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await ShizukuBundle.launch();
            },
            child: const Text('打开 Shizuku'),
          ),
        ],
      ),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _status;

    final (Color color, String subtitle) = switch (status) {
      null => (theme.colorScheme.outline, '正在检查…'),
      final s when s.ready => (
        Colors.green,
        '运行中${s.versionName == null ? '' : ' · v${s.versionName}'}',
      ),
      final s when s.installed => (
        Colors.orange,
        '已安装${s.versionName == null ? '' : ' v${s.versionName}'}，服务端未运行 · 需要 ADB 启动',
      ),
      _ => (theme.colorScheme.outline, '未安装 · 点此从 GitHub 下载并安装'),
    };

    final actionLabel = switch (status) {
      null => null,
      final s when s.ready => '打开',
      final s when s.installed => '启动指引',
      _ => '安装',
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.developer_mode_rounded, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Shizuku（QRTR / SE HAL 必需）',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: color == theme.colorScheme.outline
                        ? AppTheme.onSurfaceSubtle(context)
                        : color,
                  ),
                ),
              ],
            ),
          ),
          if (_busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (actionLabel != null)
            TextButton(onPressed: _act, child: Text(actionLabel)),
        ],
      ),
    );
  }
}
