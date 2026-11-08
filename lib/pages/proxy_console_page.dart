import 'dart:async';

import 'package:flutter/material.dart';

import '../services/proxy_linkage_service.dart';
import '../settings/app_settings.dart';
import '../widgets/glass/glass_surface.dart';
import '../widgets/styled_header_scaffold.dart';

class ProxyConsolePage extends StatefulWidget {
  const ProxyConsolePage({super.key});

  @override
  State<ProxyConsolePage> createState() => _ProxyConsolePageState();
}

class _ProxyConsolePageState extends State<ProxyConsolePage> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _secretController = TextEditingController();
  final TextEditingController _groupController = TextEditingController();

  late final ProxyLinkageService _service;

  bool _testingConnection = false;
  bool _savingConfig = false;
  bool _refreshingAll = false;
  bool _measuringAll = false;
  final Set<String> _measuringNodes = <String>{};
  final Map<String, int?> _localDelays = <String, int?>{};

  String? _connectionStatus;
  bool _connectionSuccess = false;

  bool _controllerUnreachable = false;
  List<ProxyGroupInfo> _groups = const <ProxyGroupInfo>[];
  List<ProxyNodeInfo> _nodes = const <ProxyNodeInfo>[];
  String? _selectedGroup;
  String? _currentNode;

  bool _linkageEnabled = false;
  bool _autoRestore = true;

  @override
  void initState() {
    super.initState();
    final settings = AppSettings();
    _urlController.text = settings.proxyControllerUrl;
    _secretController.text = settings.proxySecret ?? '';
    _groupController.text = settings.proxyTargetGroup;
    _selectedGroup = settings.proxyTargetGroup.trim().isEmpty
        ? 'PROXY'
        : settings.proxyTargetGroup.trim();
    _linkageEnabled = settings.proxyLinkageEnabled;
    _autoRestore = settings.proxyAutoRestore;

    _service = ProxyLinkageService(
      controllerUrl: settings.proxyControllerUrl,
      secret: settings.proxySecret,
    );

    unawaited(_initialLoad());
  }

  @override
  void dispose() {
    _urlController.dispose();
    _secretController.dispose();
    _groupController.dispose();
    super.dispose();
  }

  String _formatError(String? error) {
    if (error == null || error.isEmpty) return '未知错误';
    if (error == 'unauthorized_secret') return '密钥不正确';
    if (error.startsWith('http_')) return 'HTTP 状态码: ${error.substring(5)}';
    return error;
  }

  Future<void> _initialLoad() async {
    await _testConnectionInternal(showInlineStatus: true, loadData: true);
  }

  Future<void> _testConnectionInternal({
    required bool showInlineStatus,
    required bool loadData,
  }) async {
    setState(() {
      _testingConnection = true;
    });

    try {
      final result = await _service.testConnection();
      if (!mounted) return;

      setState(() {
        _connectionSuccess = result.alive;
        if (showInlineStatus) {
          _connectionStatus = result.alive
              ? '✅ 已连接 · ${result.version ?? 'ok'}'
              : '❌ 连接失败：${_formatError(result.error)}';
        }
        _controllerUnreachable = !result.alive;
      });

      if (result.alive && loadData) {
        await _loadGroupsAndNodes();
      } else if (!result.alive) {
        setState(() {
          _nodes = const <ProxyNodeInfo>[];
          _groups = const <ProxyGroupInfo>[];
          _currentNode = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connectionSuccess = false;
        if (showInlineStatus) {
          _connectionStatus = '❌ 连接失败：$e';
        }
        _controllerUnreachable = true;
        _nodes = const <ProxyNodeInfo>[];
        _groups = const <ProxyGroupInfo>[];
        _currentNode = null;
      });
    } finally {
      if (mounted) {
        setState(() {
          _testingConnection = false;
        });
      }
    }
  }

  Future<void> _testConnectionOnly() async {
    _service.updateConfig(
      controllerUrl: _urlController.text.trim().isEmpty
          ? 'http://127.0.0.1:9090'
          : _urlController.text.trim(),
      secret: _secretController.text.trim().isEmpty
          ? null
          : _secretController.text.trim(),
    );
    await _testConnectionInternal(showInlineStatus: true, loadData: true);
  }

  Future<void> _saveAndConnect() async {
    setState(() {
      _savingConfig = true;
    });

    try {
      final url = _urlController.text.trim().isEmpty
          ? 'http://127.0.0.1:9090'
          : _urlController.text.trim();
      final secret = _secretController.text.trim().isEmpty
          ? null
          : _secretController.text.trim();
      final targetGroup = _groupController.text.trim().isEmpty
          ? 'PROXY'
          : _groupController.text.trim();

      final settings = AppSettings();
      await settings.setProxyControllerUrl(url);
      await settings.setProxySecret(secret);
      await settings.setProxyTargetGroup(targetGroup);

      _service.updateConfig(controllerUrl: url, secret: secret);
      _selectedGroup = targetGroup;

      await _testConnectionInternal(showInlineStatus: true, loadData: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connectionSuccess = false;
        _connectionStatus = '❌ 保存或连接失败：$e';
        _controllerUnreachable = true;
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingConfig = false;
        });
      }
    }
  }

  Future<void> _loadGroupsAndNodes() async {
    try {
      final groups = await _service.getSelectorGroups();
      final savedGroup = AppSettings().proxyTargetGroup.trim();

      String activeGroup = _selectedGroup ?? savedGroup;
      if (groups.isNotEmpty) {
        final match = groups.any((g) => g.name == activeGroup);
        if (!match) {
          activeGroup = groups.first.name;
        }
      }

      final nodes = await _service.listNodes();
      String? now;
      if (activeGroup.isNotEmpty) {
        now = await _service.getCurrentNode(activeGroup);
      }

      if (!mounted) return;
      setState(() {
        _groups = groups;
        _selectedGroup = activeGroup;
        _groupController.text = activeGroup;
        _nodes = nodes;
        _currentNode = now;
        _controllerUnreachable = false;
        _localDelays.clear();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _controllerUnreachable = true;
      });
    }
  }

  Future<void> _refreshCurrentNode() async {
    final group = _selectedGroup;
    if (group == null || group.isEmpty) return;

    try {
      final now = await _service.getCurrentNode(group);
      if (!mounted) return;
      setState(() {
        _currentNode = now;
      });
    } catch (_) {}
  }

  Future<void> _onGroupChanged(String? newGroup) async {
    if (newGroup == null || newGroup.isEmpty) return;

    setState(() {
      _selectedGroup = newGroup;
      _groupController.text = newGroup;
    });

    await AppSettings().setProxyTargetGroup(newGroup);

    try {
      final now = await _service.getCurrentNode(newGroup);
      final nodes = await _service.listNodes();
      if (!mounted) return;
      setState(() {
        _currentNode = now;
        _nodes = nodes;
      });
    } catch (_) {}
  }

  Future<void> _switchNode(String nodeName) async {
    final group = _selectedGroup;
    if (group == null || group.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('❌ 切换失败：未选定策略组')),
      );
      return;
    }

    try {
      final result = await _service.selectNode(group, nodeName);
      if (!mounted) return;

      if (result.success) {
        setState(() {
          _currentNode = result.currentNode ?? nodeName;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ 已切换到 $nodeName')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ 切换失败：${_formatError(result.error)}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ 切换失败：$e')),
      );
    }
  }

  Future<void> _measureNodeDelay(String nodeName) async {
    setState(() {
      _measuringNodes.add(nodeName);
    });

    try {
      final delay = await _service.measureDelay(nodeName);
      if (!mounted) return;
      setState(() {
        _localDelays[nodeName] = delay;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _localDelays[nodeName] = null;
      });
    } finally {
      if (mounted) {
        setState(() {
          _measuringNodes.remove(nodeName);
        });
      }
    }
  }

  Future<void> _refreshAll() async {
    if (_refreshingAll) return;
    setState(() => _refreshingAll = true);
    try {
      await _testConnectionInternal(showInlineStatus: false, loadData: true);
    } finally {
      if (mounted) {
        setState(() => _refreshingAll = false);
      }
    }
  }

  Future<void> _measureAllNodes() async {
    if (_measuringAll || _nodes.isEmpty) return;
    setState(() => _measuringAll = true);
    try {
      for (final node in _nodes) {
        if (!mounted) break;
        await _measureNodeDelay(node.name);
      }
    } finally {
      if (mounted) {
        setState(() => _measuringAll = false);
      }
    }
  }

  Color _delayColor(int? delay, ColorScheme scheme) {
    if (delay == null) return scheme.onSurfaceVariant;
    if (delay < 200) return Colors.green;
    if (delay < 500) return Colors.orange;
    return scheme.error;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
    );

    return StyledHeaderScaffold(
      showBackButton: false,
      title: '代理控制台',
      subtitle: '不切卡也能单独切换节点',
      actions: [
        IconButton(
          tooltip: '刷新所有状态',
          icon: _refreshingAll
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          onPressed: _refreshingAll ? null : _refreshAll,
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _buildConnectionCard(theme, inputBorder),
          const SizedBox(height: 16),
          _buildSelectorGroupCard(theme, inputBorder),
          const SizedBox(height: 16),
          _buildCurrentNodeCard(theme),
          const SizedBox(height: 16),
          _buildNodeListCard(theme),
          const SizedBox(height: 16),
          _buildAutomationCard(theme),
        ],
      ),
    );
  }

  Widget _buildConnectionCard(ThemeData theme, InputBorder inputBorder) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.router_outlined, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                '控制器连接',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _urlController,
            decoration: InputDecoration(
              labelText: '控制器地址',
              hintText: 'http://127.0.0.1:9090',
              border: inputBorder,
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _secretController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'Secret',
              hintText: '留空表示无密钥',
              border: inputBorder,
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _groupController,
            decoration: InputDecoration(
              labelText: '策略组',
              hintText: 'PROXY / 🚀 节点选择',
              border: inputBorder,
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _savingConfig ? null : _saveAndConnect,
                  icon: _savingConfig
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.save_outlined, size: 18),
                  label: const Text('保存并连接'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testingConnection ? null : _testConnectionOnly,
                  icon: _testingConnection
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sensors_outlined, size: 18),
                  label: const Text('仅测试连接'),
                ),
              ),
            ],
          ),
          if (_connectionStatus != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _connectionSuccess
                    ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
                    : theme.colorScheme.errorContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _connectionStatus!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _connectionSuccess
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSelectorGroupCard(ThemeData theme, InputBorder inputBorder) {
    final groupList = _groups;
    final currentValue = _selectedGroup;
    final hasMatch = groupList.any((g) => g.name == currentValue);
    final effectiveValue = hasMatch
        ? currentValue
        : (groupList.isNotEmpty ? groupList.first.name : null);

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.alt_route_outlined, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                '策略组选择',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey(effectiveValue),
            initialValue: effectiveValue,
            decoration: InputDecoration(
              labelText: '目标策略组',
              border: inputBorder,
              isDense: true,
            ),
            items: groupList.map((g) {
              return DropdownMenuItem<String>(
                value: g.name,
                child: Text(
                  '${g.name} (${g.all.length}个节点)',
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }).toList(),
            onChanged: groupList.isEmpty ? null : _onGroupChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentNodeCard(ThemeData theme) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Icon(Icons.hub_outlined, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      text: '当前：',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      children: [
                        TextSpan(
                          text: _currentNode ?? '未知',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: _refreshCurrentNode,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('刷新'),
          ),
        ],
      ),
    );
  }

  Widget _buildNodeListCard(ThemeData theme) {
    if (_controllerUnreachable) {
      return GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off_outlined, size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(
                '控制器不可达，请检查地址与 FlClash / Mihomo 的「外部控制」是否开启。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_nodes.isEmpty) {
      return GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Center(
          child: Text(
            '暂无可用节点',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return GlassCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Icon(Icons.list_alt_outlined, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  '节点列表 (${_nodes.length})',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _measuringAll ? null : _measureAllNodes,
                  icon: _measuringAll
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.speed, size: 16),
                  label: const Text('全部测速'),
                ),
              ],
            ),
          ),
          const Divider(height: 16),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _nodes.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final node = _nodes[index];
              final isCurrent = _currentNode != null && _currentNode == node.name;
              final delay = _localDelays.containsKey(node.name)
                  ? _localDelays[node.name]
                  : node.delay;
              final isMeasuring = _measuringNodes.contains(node.name);

              return Container(
                decoration: BoxDecoration(
                  color: isCurrent
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(12),
                  border: isCurrent
                      ? Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.6), width: 1.5)
                      : null,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            node.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                              color: isCurrent
                                  ? theme.colorScheme.onPrimaryContainer
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  node.type,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSecondaryContainer,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                delay == null ? '—' : '$delay ms',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: _delayColor(delay, theme.colorScheme),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '测速',
                      icon: isMeasuring
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.speed, size: 20),
                      onPressed: isMeasuring ? null : () => _measureNodeDelay(node.name),
                    ),
                    const SizedBox(width: 4),
                    TextButton(
                      onPressed: () => _switchNode(node.name),
                      child: const Text('切换'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAutomationCard(ThemeData theme) {
    final subtle = theme.colorScheme.onSurfaceVariant;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_mode_outlined, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                '自动化设置',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('切卡时自动按卡国别切节点'),
            subtitle: Text(
              '仅在切卡事件发生时生效；关闭后在此控制台仍可随时手动切换节点',
              style: TextStyle(fontSize: 12, color: subtle),
            ),
            value: _linkageEnabled,
            onChanged: (v) async {
              setState(() => _linkageEnabled = v);
              await AppSettings().setProxyLinkageEnabled(v);
            },
          ),
          const Divider(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('切回默认卡时还原切卡前的节点'),
            subtitle: Text(
              '仅在主卡还原回滚时自动生效；在此页面手动切换节点不受此开关限制',
              style: TextStyle(fontSize: 12, color: subtle),
            ),
            value: _autoRestore,
            onChanged: (v) async {
              setState(() => _autoRestore = v);
              await AppSettings().setProxyAutoRestore(v);
            },
          ),
        ],
      ),
    );
  }
}
