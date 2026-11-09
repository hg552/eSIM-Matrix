import 'package:flutter/material.dart';
import 'dart:async';

import '../glass/glass_surface.dart';
import '../../services/proxy_linkage_service.dart';
import '../../settings/app_settings.dart';

/// Picker shown from a profile's long-press menu. It reads the live node list
/// from the Clash external controller and returns either a concrete node name,
/// '' for "clear the binding / auto match", or null when cancelled.
class ProxyNodePickerDialog extends StatefulWidget {
  const ProxyNodePickerDialog({
    super.key,
    required this.profileName,
    required this.iccid,
    required this.currentNode,
    required this.settings,
    this.initialNodes,
  });

  /// Pre-loaded node list for tests and callers that already have it. When set,
  /// the external controller is not queried at all.
  final List<String>? initialNodes;


  final String profileName;
  final String iccid;
  final String? currentNode;
  final AppSettings settings;

  @override
  State<ProxyNodePickerDialog> createState() => _ProxyNodePickerDialogState();
}

class _ProxyNodePickerDialogState extends State<ProxyNodePickerDialog> {
  static const String _auto = '__AUTO__';

  final TextEditingController _manualController = TextEditingController();
  List<String> _nodes = const <String>[];
  bool _loading = true;
  bool _loadFailed = false;
  bool _manual = false;
  late String _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.currentNode ?? _auto;
    _manualController.text = widget.currentNode ?? '';
    final preloaded = widget.initialNodes;
    if (preloaded != null) {
      _nodes = preloaded;
      _loading = false;
    } else {
      unawaited(_loadNodes());
    }
  }

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  Future<void> _loadNodes() async {
    final client = ProxyLinkageService(
      controllerUrl: widget.settings.proxyControllerUrl,
      secret: widget.settings.proxySecret,
    );
    try {
      final group = await client.getGroup(widget.settings.proxyTargetGroup);
      if (group == null || group.all.isEmpty) {
        throw StateError('controller_unavailable');
      }
      if (!mounted) return;
      setState(() {
        _nodes = group.all;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadFailed = true;
        _loading = false;
      });
    } finally {
      client.close();
    }
  }

  bool get _manualMode => _manual || _loadFailed || _nodes.isEmpty;

  String _result() => _manualMode
      ? _manualController.text.trim()
      : (_selected == _auto ? '' : _selected);

  Widget _manualEditor(String hint) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(hint, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 10),
        TextField(
          controller: _manualController,
          decoration: const InputDecoration(
            labelText: '节点名称（留空 = 按国别自动匹配）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ],
    );
  }

  Widget _nodeList() {
    return ListView(
      children: [
        ListTile(
          leading: Icon(
            _selected == _auto
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
          ),
          title: const Text('自动匹配（按卡国别）'),
          subtitle: const Text('不指定节点，用国旗 / 区号 / 关键词推导'),
          onTap: () => setState(() {
            _selected = _auto;
            _manual = false;
          }),
        ),
        const Divider(height: 1),
        ..._nodes.map(
          (node) => ListTile(
            leading: Icon(
              _selected == node
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            title: Text(node, overflow: TextOverflow.ellipsis),
            onTap: () => setState(() {
              _selected = node;
              _manual = false;
            }),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('手动输入节点名…'),
          onTap: () => setState(() => _manual = true),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isGlass = AppSettings().enableGlassUi;
    final isDark = theme.brightness == Brightness.dark;
    final glassBg = isDark
        ? const Color(0xFF141B2D).withValues(alpha: 0.65)
        : Colors.white.withValues(alpha: 0.72);
    final suffix = widget.iccid.length > 4
        ? widget.iccid.substring(widget.iccid.length - 4)
        : widget.iccid;

    Widget dialogChild = AlertDialog(
      backgroundColor: isGlass ? glassBg : null,
      surfaceTintColor: isGlass ? Colors.transparent : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Text('指定代理节点'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.profileName}  ·  ICCID 尾号 $suffix',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              '切到这张卡时，自动把策略组【${widget.settings.proxyTargetGroup}】切到你选的节点。',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 280,
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : (_manualMode ? _manualEditor(
                          _loadFailed
                              ? '控制器未连接或策略组为空，可手动输入节点名：'
                              : '手动输入节点名（留空 = 自动匹配）：',
                        )
                        : _nodeList()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _result()),
          child: const Text('保存'),
        ),
      ],
    );

    if (isGlass) {
      return GlassSurface(
        radius: 24,
        child: dialogChild,
      );
    }
    return dialogChild;
  }
}
