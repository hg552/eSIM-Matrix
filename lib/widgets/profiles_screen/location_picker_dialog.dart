import 'package:flutter/material.dart';
import '../glass/glass_surface.dart';
import '../../services/location_mapping_resolver.dart';
import '../../settings/app_settings.dart';

/// Picker dialog for binding an eSIM profile to a specific virtual location template
/// or custom latitude/longitude coordinates.
/// Returns:
/// - A formatted string `latitude, longitude, cityName` on confirmation.
/// - `''` to clear the custom binding (reverting to auto country-match).
/// - `null` when cancelled.
class LocationPickerDialog extends StatefulWidget {
  const LocationPickerDialog({
    super.key,
    required this.profileName,
    required this.iccid,
    required this.currentLocationRule,
    required this.settings,
    this.initialTemplates,
  });

  final String profileName;
  final String iccid;
  final String? currentLocationRule;
  final AppSettings settings;
  final List<LocationTemplate>? initialTemplates;

  @override
  State<LocationPickerDialog> createState() => _LocationPickerDialogState();
}

class _LocationPickerDialogState extends State<LocationPickerDialog> {
  static const String _autoKey = '__AUTO__';

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _latController = TextEditingController();
  final TextEditingController _lngController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();

  bool _isManualMode = false;
  bool _saveAsTemplate = false;
  String _selectedTemplateId = _autoKey;
  String? _manualError;

  late List<LocationTemplate> _templates;

  @override
  void initState() {
    super.initState();
    _templates = widget.initialTemplates ?? widget.settings.allLocationTemplates;

    final current = widget.currentLocationRule?.trim();
    if (current != null && current.isNotEmpty) {
      // Check if current matches an existing template
      final matched = _templates.firstWhere(
        (t) => current.startsWith('${t.latitude}, ${t.longitude}') || current == t.formattedValue,
        orElse: () => const LocationTemplate(
          id: '__CUSTOM_MATCH__',
          name: '',
          latitude: 0,
          longitude: 0,
          countryCode: '',
        ),
      );

      if (matched.id != '__CUSTOM_MATCH__') {
        _selectedTemplateId = matched.id;
      } else {
        // Pre-fill manual mode
        _isManualMode = true;
        final parts = current.split(',');
        if (parts.isNotEmpty) _latController.text = parts[0].trim();
        if (parts.length > 1) _lngController.text = parts[1].trim();
        if (parts.length > 2) _nameController.text = parts.sublist(2).join(',').trim();
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _latController.dispose();
    _lngController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  List<LocationTemplate> get _filteredTemplates {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _templates;
    return _templates.where((t) {
      return t.name.toLowerCase().contains(query) ||
          t.countryCode.toLowerCase().contains(query) ||
          t.latitude.toString().contains(query) ||
          t.longitude.toString().contains(query);
    }).toList();
  }

  void _validateAndSubmitManual() {
    final latStr = _latController.text.trim();
    final lngStr = _lngController.text.trim();
    final name = _nameController.text.trim().isEmpty ? '自定义地点' : _nameController.text.trim();

    final lat = double.tryParse(latStr);
    final lng = double.tryParse(lngStr);

    if (lat == null || !lat.isFinite || lat < -90.0 || lat > 90.0) {
      setState(() => _manualError = '纬度必须为 -90.0 到 90.0 之间的数值');
      return;
    }
    if (lng == null || !lng.isFinite || lng < -180.0 || lng > 180.0) {
      setState(() => _manualError = '经度必须为 -180.0 到 180.0 之间的数值');
      return;
    }

    if (_saveAsTemplate) {
      final newTpl = LocationTemplate(
        id: 'user_${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        latitude: lat,
        longitude: lng,
        countryCode: 'XX',
        isCustom: true,
      );
      widget.settings.addUserLocationTemplate(newTpl);
    }

    final result = '$lat, $lng, $name';
    Navigator.of(context).pop(result);
  }

  void _submitSelection() {
    if (_isManualMode) {
      _validateAndSubmitManual();
      return;
    }

    if (_selectedTemplateId == _autoKey) {
      Navigator.of(context).pop(''); // Clear custom rule -> auto match
      return;
    }

    final tpl = _templates.firstWhere((t) => t.id == _selectedTemplateId);
    Navigator.of(context).pop(tpl.formattedValue);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final glass = AppSettings().enableGlassUi;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      backgroundColor: glass ? Colors.transparent : null,
      surfaceTintColor: glass ? Colors.transparent : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: GlassSurface(
        radius: 16,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 680),
          child: Padding(
            padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Icon(Icons.location_on, color: theme.colorScheme.primary, size: 24),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '指定虚拟定位 · ${widget.profileName}',
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          'ICCID: ${widget.iccid}',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Mode segmented button
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('常用定位模板'),
                    icon: Icon(Icons.bookmarks_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('手动输入经纬度'),
                    icon: Icon(Icons.edit_location_alt_outlined, size: 16),
                  ),
                ],
                selected: {_isManualMode},
                onSelectionChanged: (set) {
                  setState(() {
                    _isManualMode = set.first;
                    _manualError = null;
                  });
                },
              ),
              const SizedBox(height: 12),

              // Content Area
              Expanded(
                child: _isManualMode ? _buildManualForm(theme) : _buildTemplateList(theme),
              ),

              const SizedBox(height: 16),

              // Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (widget.currentLocationRule != null && widget.currentLocationRule!.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).pop(''),
                      icon: const Icon(Icons.clear, size: 16),
                      label: const Text('清除指定'),
                      style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _submitSelection,
                    child: const Text('确定绑定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildTemplateList(ThemeData theme) {
    final filtered = _filteredTemplates;

    return Column(
      children: [
        // Search field
        TextField(
          controller: _searchController,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: '搜索地名、国家或经纬度…',
            prefixIcon: const Icon(Icons.search, size: 20),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
        ),
        const SizedBox(height: 8),

        Expanded(
          child: ListView(
            children: [
              // Auto country match option
              RadioListTile<String>(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                value: _autoKey,
                // ignore: deprecated_member_use
                groupValue: _selectedTemplateId,
                title: const Text('🌐 自动根据卡国别匹配', style: TextStyle(fontWeight: FontWeight.w600)),
                subtitle: const Text('切卡时根据卡片别名/MCC 自动推导该国代表城市坐标'),
                // ignore: deprecated_member_use
                onChanged: (val) => setState(() => _selectedTemplateId = val ?? _autoKey),
              ),
              const Divider(height: 1),

              ...filtered.map((tpl) {
                final isSelected = _selectedTemplateId == tpl.id;
                return RadioListTile<String>(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  value: tpl.id,
                  // ignore: deprecated_member_use
                  groupValue: _selectedTemplateId,
                  // ignore: deprecated_member_use
                  onChanged: (val) => setState(() => _selectedTemplateId = val ?? tpl.id),
                  title: Row(
                    children: [
                      Text(tpl.flagEmoji, style: const TextStyle(fontSize: 16)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          tpl.name,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (tpl.isCustom)
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          tooltip: '删除自定义模板',
                          onPressed: () async {
                            await widget.settings.deleteUserLocationTemplate(tpl.id);
                            setState(() {
                              _templates = widget.settings.allLocationTemplates;
                              if (_selectedTemplateId == tpl.id) _selectedTemplateId = _autoKey;
                            });
                          },
                        ),
                    ],
                  ),
                  subtitle: Text(
                    '${tpl.latitude.toStringAsFixed(4)}, ${tpl.longitude.toStringAsFixed(4)}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildManualForm(ThemeData theme) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '直接输入任意经纬度，切卡时将直接注入该坐标：',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _latController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: InputDecoration(
              labelText: '纬度 (Latitude)',
              hintText: '例: 22.3193 (-90.0 ~ 90.0)',
              prefixIcon: const Icon(Icons.explore_outlined),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _lngController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: InputDecoration(
              labelText: '经度 (Longitude)',
              hintText: '例: 114.1694 (-180.0 ~ 180.0)',
              prefixIcon: const Icon(Icons.explore),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 12),

          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: '地点/备注名称',
              hintText: '例: 香港尖沙咀天星码头',
              prefixIcon: const Icon(Icons.label_outline),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 8),

          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _saveAsTemplate,
            title: const Text('保存为常用模板（其他卡片可直接选用）'),
            onChanged: (v) => setState(() => _saveAsTemplate = v ?? false),
          ),

          if (_manualError != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _manualError!,
                style: TextStyle(color: theme.colorScheme.onErrorContainer, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
