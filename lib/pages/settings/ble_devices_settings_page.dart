import 'package:flutter/material.dart';

import '../../adapter/ble/nble_sim_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../widgets/styled_header_scaffold.dart';

class BleDevicesSettingsPage extends StatefulWidget {
  const BleDevicesSettingsPage({super.key});

  @override
  State<BleDevicesSettingsPage> createState() => _BleDevicesSettingsPageState();
}

class _BleDevicesSettingsPageState extends State<BleDevicesSettingsPage> {
  late Future<List<NBLESimStoredPassword>> _recordsFuture;
  final Set<String> _revealedDevices = <String>{};

  @override
  void initState() {
    super.initState();
    _recordsFuture = NBLESimAdapter.loadStoredPasswords();
  }

  void _reload() {
    setState(() {
      _recordsFuture = NBLESimAdapter.loadStoredPasswords();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return StyledHeaderScaffold(
      title: l10n.savedBleDevices,
      subtitle: l10n.savedBleDevicesSubtitle,
      actions: [
        IconButton(
          tooltip: MaterialLocalizations.of(
            context,
          ).refreshIndicatorSemanticLabel,
          onPressed: _reload,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      body: FutureBuilder<List<NBLESimStoredPassword>>(
        future: _recordsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(snapshot.error.toString()),
              ),
            );
          }

          final records = snapshot.data ?? const <NBLESimStoredPassword>[];
          if (records.isEmpty) {
            return _buildEmptyState(context, l10n);
          }

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _buildDescriptionCard(context, l10n),
              const SizedBox(height: 16),
              for (final record in records) ...[
                _buildRecordCard(context, record, l10n),
                const SizedBox(height: 12),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildDescriptionCard(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n.savedBleDevicesDescription,
              style: TextStyle(color: theme.colorScheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordCard(
    BuildContext context,
    NBLESimStoredPassword record,
    AppLocalizations l10n,
  ) {
    final theme = Theme.of(context);
    final revealed = _revealedDevices.contains(record.deviceName);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.surfaceSubtle(context)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            Icons.bluetooth_rounded,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(
          record.deviceName,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Text('${l10n.password}: '),
              Expanded(
                child: SelectableText(
                  revealed ? record.password : '••••••',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
        trailing: IconButton(
          tooltip: revealed ? 'Hide password' : 'Show password',
          onPressed: () {
            setState(() {
              if (revealed) {
                _revealedDevices.remove(record.deviceName);
              } else {
                _revealedDevices.add(record.deviceName);
              }
            });
          },
          icon: Icon(
            revealed
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bluetooth_disabled_rounded,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.noSavedBleDevices,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}
