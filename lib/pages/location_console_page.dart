import 'package:flutter/material.dart';

import '../services/location_mapping_resolver.dart';
import '../services/mock_location_service.dart';
import '../services/remote_gateway_service.dart';
import '../settings/app_settings.dart';
import '../widgets/glass/glass_surface.dart';
import '../widgets/styled_header_scaffold.dart';

class LocationConsolePage extends StatefulWidget {
  const LocationConsolePage({super.key});

  @override
  State<LocationConsolePage> createState() => _LocationConsolePageState();
}

class _LocationConsolePageState extends State<LocationConsolePage> {
  final MockLocationService _mockLocationService = const MockLocationService();
  final AppSettings _settings = AppSettings();

  MockLocationStatus? _status;
  bool _loadingStatus = true;
  bool _injecting = false;

  // Selected mode
  late String _mode;

  // Selected coordinates for injection
  double _selectedLat = 22.3193;
  double _selectedLng = 114.1694;
  String _selectedLabel = '中国香港 · 尖沙咀海旁';

  // Section 4 tabs: true = 常用模板, false = 手动输入
  bool _isTemplateTab = true;

  // Search filter for templates
  final TextEditingController _searchController = TextEditingController();
  String _searchKeyword = '';

  // Manual input fields
  final TextEditingController _latController = TextEditingController();
  final TextEditingController _lngController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  bool _saveAsTemplate = false;
  String? _latError;
  String? _lngError;

  @override
  void initState() {
    super.initState();
    _mode = _settings.mockLocationMode;
    final templates = LocationMappingResolver.builtInTemplates;
    if (templates.isNotEmpty) {
      final initial = templates.first;
      _selectedLat = initial.latitude;
      _selectedLng = initial.longitude;
      _selectedLabel = initial.name;
    }
    // Reopen where the user left off, not on the first built-in template.
    final remembered = _settings.lastMockLocationRule;
    if (remembered != null) {
      final parts = remembered.split(',');
      final lat = parts.isNotEmpty ? double.tryParse(parts[0].trim()) : null;
      final lng = parts.length > 1 ? double.tryParse(parts[1].trim()) : null;
      if (lat != null && lng != null) {
        _selectedLat = lat;
        _selectedLng = lng;
        _selectedLabel = parts.length > 2
            ? parts.sublist(2).join(',').trim()
            : '自定义地点';
      }
    }
    _latController.text = _selectedLat.toString();
    _lngController.text = _selectedLng.toString();
    _nameController.text = _selectedLabel;

    _loadStatus();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _latController.dispose();
    _lngController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    setState(() => _loadingStatus = true);
    try {
      final status = await _mockLocationService.getStatus();
      if (mounted) {
        setState(() {
          _status = status;
          _loadingStatus = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingStatus = false);
      }
    }
  }

  Future<void> _applyInjection() async {
    if (!_isTemplateTab) {
      if (!_validateAndApplyManualInputs()) {
        return;
      }
    }

    setState(() => _injecting = true);
    try {
      final success = await RemoteGatewayService.instance.applyManualLocation(
        latitude: _selectedLat,
        longitude: _selectedLng,
        label: _selectedLabel,
        mode: _mode,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success ? '✅ 注入成功' : '❌ 注入失败：请检查上面的权限状态',
            ),
          ),
        );
      }
      if (success) {
        await _settings.setLastMockLocationRule(
          '$_selectedLat, $_selectedLng, $_selectedLabel',
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ 注入失败：请检查上面的权限状态')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _injecting = false);
      }
      await _loadStatus();
    }
  }

  Future<void> _stopInjection() async {
    setState(() => _injecting = true);
    try {
      await RemoteGatewayService.instance.stopMockLocation();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已停止注入')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('停止注入失败')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _injecting = false);
      }
      await _loadStatus();
    }
  }

  bool _validateAndApplyManualInputs() {
    final latText = _latController.text.trim();
    final lngText = _lngController.text.trim();
    final nameText = _nameController.text.trim();

    double? lat = double.tryParse(latText);
    double? lng = double.tryParse(lngText);

    String? latErr;
    String? lngErr;

    if (lat == null || !lat.isFinite) {
      latErr = '请输入有效纬度 (-90 ~ 90)';
    } else if (lat < -90.0 || lat > 90.0) {
      latErr = '纬度范围必须在 -90 到 90 之间';
    }

    if (lng == null || !lng.isFinite) {
      lngErr = '请输入有效经度 (-180 ~ 180)';
    } else if (lng < -180.0 || lng > 180.0) {
      lngErr = '经度范围必须在 -180 到 180 之间';
    }

    setState(() {
      _latError = latErr;
      _lngError = lngErr;
    });

    if (latErr != null || lngErr != null) {
      return false;
    }

    final finalLat = lat!;
    final finalLng = lng!;
    final finalName = nameText.isEmpty ? '自定义地点' : nameText;

    setState(() {
      _selectedLat = finalLat;
      _selectedLng = finalLng;
      _selectedLabel = finalName;
    });

    if (_saveAsTemplate) {
      final tpl = LocationTemplate(
        id: 'user_${DateTime.now().millisecondsSinceEpoch}',
        name: finalName,
        latitude: finalLat,
        longitude: finalLng,
        countryCode: 'XX',
        isCustom: true,
      );
      _settings.addUserLocationTemplate(tpl);
    }

    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return StyledHeaderScaffold(
      showBackButton: false,
      title: '虚拟定位',
      subtitle: '不切卡也能单独使用',
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: '刷新状态',
          onPressed: _loadingStatus ? null : _loadStatus,
        ),
      ],
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatusCard(theme),
            const SizedBox(height: 16),
            _buildModeSelector(theme),
            const SizedBox(height: 16),
            _buildActionButtons(theme),
            const SizedBox(height: 16),
            _buildLocationSelector(theme),
            const SizedBox(height: 16),
            _buildLinkageSwitch(theme),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard(ThemeData theme) {
    final status = _status;
    final isMocking = status?.isMocking ?? false;
    final isMockApp = status?.isMockApp ?? false;
    final isShizukuAvailable = status?.isShizukuAvailable ?? false;
    final providers = status?.providers ?? const <String>[];

    final coordText = isMocking && status != null
        ? '${status.latitude.toStringAsFixed(5)}, ${status.longitude.toStringAsFixed(5)}'
        : '—';
    final providerText = providers.isEmpty
        ? '无（未注册测试 Provider）'
        : providers.join(' / ');

    final bothUnavailable = !isMockApp && !isShizukuAvailable;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '状态',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (_loadingStatus)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _buildStatusRow(
            '注入状态',
            isMocking ? '🟢 正在注入' : '⚪ 未注入',
            theme,
          ),
          const SizedBox(height: 8),
          _buildStatusRow('当前坐标', coordText, theme),
          const SizedBox(height: 8),
          _buildStatusRow('生效通道', providerText, theme),
          const SizedBox(height: 8),
          _buildStatusRow(
            '权限',
            '系统模拟位置：${isMockApp ? '✅ 已授权' : '❌ 未授权'}\nShizuku：${isShizukuAvailable ? '✅ 可用' : '❌ 不可用'}',
            theme,
          ),
          if (bothUnavailable) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '两种通道都不可用：请到「开发者选项 → 选择模拟位置信息应用」选择本应用，或启动并授权 Shizuku。',
                style: TextStyle(
                  color: theme.colorScheme.onErrorContainer,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusRow(String label, String value, ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildModeSelector(ThemeData theme) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '通道选择',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment<String>(
                  value: 'system',
                  label: Text('系统模拟位置'),
                ),
                ButtonSegment<String>(
                  value: 'shizuku',
                  label: Text('Shizuku 注入'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (Set<String> newSelection) {
                final selected = newSelection.first;
                setState(() => _mode = selected);
                _settings.setMockLocationMode(selected);
              },
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '系统模式需要开发者选项授权；Shizuku 模式通过 shell 注册测试 Provider，二者可同时开启。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: _injecting ? null : _applyInjection,
          icon: const Icon(Icons.gps_fixed),
          label: Text(_injecting ? '处理中...' : '注入当前坐标'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _injecting ? null : _stopInjection,
          icon: const Icon(Icons.gps_off),
          label: const Text('停止注入'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLocationSelector(ThemeData theme) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '地点选择',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment<bool>(
                  value: true,
                  label: Text('常用模板'),
                ),
                ButtonSegment<bool>(
                  value: false,
                  label: Text('手动输入'),
                ),
              ],
              selected: {_isTemplateTab},
              onSelectionChanged: (Set<bool> newSelection) {
                setState(() {
                  _isTemplateTab = newSelection.first;
                });
              },
            ),
          ),
          const SizedBox(height: 16),
          if (_isTemplateTab)
            _buildTemplateListSection(theme)
          else
            _buildManualInputSection(theme),
        ],
      ),
    );
  }

  Widget _buildTemplateListSection(ThemeData theme) {
    final allTemplates = _settings.allLocationTemplates;
    final query = _searchKeyword.trim().toLowerCase();

    final filtered = allTemplates.where((tpl) {
      if (query.isEmpty) return true;
      final name = tpl.name.toLowerCase();
      final cc = tpl.countryCode.toLowerCase();
      final lat = tpl.latitude.toString();
      final lng = tpl.longitude.toString();
      return name.contains(query) ||
          cc.contains(query) ||
          lat.contains(query) ||
          lng.contains(query);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: '搜索地名、国家或经纬度…',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _searchKeyword.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchKeyword = '');
                    },
                  )
                : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
          onChanged: (val) {
            setState(() => _searchKeyword = val);
          },
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 280,
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    '无匹配模板',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                )
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final tpl = filtered[index];
                    final isSelected = (_selectedLat - tpl.latitude).abs() <
                            0.00001 &&
                        (_selectedLng - tpl.longitude).abs() < 0.00001;

                    return Card(
                      elevation: 0,
                      color: isSelected
                          ? theme.colorScheme.primaryContainer
                          : theme.colorScheme.surfaceContainerHighest.withValues(
                              alpha: 0.4,
                            ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        leading: Text(
                          tpl.flagEmoji,
                          style: const TextStyle(fontSize: 24),
                        ),
                        title: Text(
                          tpl.name,
                          style: TextStyle(
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: isSelected
                                ? theme.colorScheme.onPrimaryContainer
                                : null,
                          ),
                        ),
                        subtitle: Text(
                          '${tpl.latitude}, ${tpl.longitude}',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: isSelected
                                ? theme.colorScheme.onPrimaryContainer
                                    .withValues(alpha: 0.8)
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: tpl.isCustom
                            ? IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: '删除自定义模板',
                                onPressed: () async {
                                  await _settings
                                      .deleteUserLocationTemplate(tpl.id);
                                  setState(() {});
                                },
                              )
                            : null,
                        onTap: () {
                          setState(() {
                            _selectedLat = tpl.latitude;
                            _selectedLng = tpl.longitude;
                            _selectedLabel = tpl.name;
                            _latController.text = tpl.latitude.toString();
                            _lngController.text = tpl.longitude.toString();
                            _nameController.text = tpl.name;
                          });
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildManualInputSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _latController,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: InputDecoration(
            labelText: '纬度 (-90 ~ 90)',
            errorText: _latError,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onChanged: (_) {
            if (_latError != null) {
              setState(() => _latError = null);
            }
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _lngController,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: InputDecoration(
            labelText: '经度 (-180 ~ 180)',
            errorText: _lngError,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onChanged: (_) {
            if (_lngError != null) {
              setState(() => _lngError = null);
            }
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _nameController,
          decoration: InputDecoration(
            labelText: '地点名称',
            hintText: '自定义地点',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          title: const Text('保存为常用模板'),
          value: _saveAsTemplate,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          onChanged: (val) {
            setState(() => _saveAsTemplate = val ?? false);
          },
        ),
      ],
    );
  }

  Widget _buildLinkageSwitch(ThemeData theme) {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: SwitchListTile(
        title: const Text(
          '切卡时自动注入对应国家定位',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '关闭时本页仍可手动注入；开启后切卡会自动按卡国别注入。',
          style: TextStyle(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 13,
          ),
        ),
        value: _settings.mockLocationLinkageEnabled,
        onChanged: (val) async {
          await _settings.setMockLocationLinkageEnabled(val);
          if (mounted) setState(() {});
        },
      ),
    );
  }
}
