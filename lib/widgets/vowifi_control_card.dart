import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/remote_profile_controller.dart';
import '../services/vowifi_platform_service.dart';
import '../settings/app_settings.dart';
import '../widgets/glass/glass_surface.dart';

/// Controls the phone's own Wi-Fi Calling switch for the selected subscription.
///
/// This is a different feature from the VoWiFi tab, which runs its own ePDG
/// tunnel from a card reader: this card flips the switch the platform's
/// ImsService honours, so the carrier's own number becomes reachable over Wi-Fi
/// in the system dialer and SMS app.
class VowifiControlCard extends StatefulWidget {
  const VowifiControlCard({super.key, required this.controller});

  final RemoteProfileControl controller;

  @override
  State<VowifiControlCard> createState() => _VowifiControlCardState();
}

class _VowifiControlCardState extends State<VowifiControlCard> {
  final VowifiService _platform = const VowifiService();

  VowifiCapabilities? _capabilities;
  VowifiStatus? _status;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final capabilities = await _platform.capabilities();
      final status = await widget.controller.vowifiStatus();
      if (!mounted) return;
      setState(() {
        _capabilities = capabilities;
        _status = status;
        _loading = false;
        // A null status means the controller could not resolve which
        // subscription the selected reader serves. Saying so is more useful
        // than showing an empty card that looks like a bug.
        if (status == null) _error = 'no_subscription';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _apply(Future<VowifiStatus?> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await action();
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (status == null) {
          _error = 'write_failed';
        } else {
          _status = status;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _reload() async {
    setState(() => _busy = true);
    final ok = await widget.controller.reloadVowifi();
    if (!mounted) return;
    setState(() => _busy = false);
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? l10n.wfcReloaded : l10n.wfcWriteFailed)),
    );
    if (ok) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final capabilities = _capabilities;
    final status = _status;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _wrap(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wifi_calling_3, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l10n.wfcTitle, style: theme.textTheme.titleMedium),
                      Text(l10n.wfcSubtitle, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                if (_busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (capabilities != null && !capabilities.usable)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  l10n.wfcRootRequired,
                  style: theme.textTheme.bodySmall,
                ),
              )
            else if (_error == 'no_subscription')
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  l10n.wfcNoSubscription,
                  style: theme.textTheme.bodySmall,
                ),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '${l10n.wfcWriteFailed}\n$_error',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              )
            else if (status != null) ...[
              const Divider(height: 24),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.wfcEnabled),
                value: status.enabled,
                onChanged: _busy
                    ? null
                    : (value) => _apply(
                        () => widget.controller.setVowifiEnabled(value),
                      ),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.wfcRoamingEnabled),
                value: status.roamingEnabled,
                onChanged: _busy
                    ? null
                    : (value) => _apply(
                        () => widget.controller.setVowifiRoamingEnabled(value),
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                _modeLabel(l10n, status.mode),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              SegmentedButton<VowifiCallingMode>(
                segments: [
                  ButtonSegment(
                    value: VowifiCallingMode.wifiOnly,
                    label: Text(l10n.wfcModeWifiOnly),
                  ),
                  ButtonSegment(
                    value: VowifiCallingMode.wifiPreferred,
                    label: Text(l10n.wfcModeWifiPreferred),
                  ),
                  ButtonSegment(
                    value: VowifiCallingMode.cellularPreferred,
                    label: Text(l10n.wfcModeCellularPreferred),
                  ),
                ],
                selected: {
                  status.mode == VowifiCallingMode.unknown
                      ? VowifiCallingMode.wifiOnly
                      : status.mode,
                },
                emptySelectionAllowed: false,
                onSelectionChanged: _busy
                    ? null
                    : (selection) => _apply(
                        () => widget.controller.setVowifiMode(selection.first),
                      ),
              ),
              const SizedBox(height: 12),
              Text(l10n.wfcReloadHint, style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _reload,
                  icon: const Icon(Icons.restart_alt),
                  label: Text(l10n.wfcReload),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _wrap(Widget child) {
    if (AppSettings().enableGlassUi) {
      return GlassSurface(
        radius: 20,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      );
    }
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }

  static String _modeLabel(AppLocalizations l10n, VowifiCallingMode mode) =>
      switch (mode) {
        VowifiCallingMode.wifiOnly => l10n.wfcModeWifiOnly,
        VowifiCallingMode.wifiPreferred => l10n.wfcModeWifiPreferred,
        VowifiCallingMode.cellularPreferred => l10n.wfcModeCellularPreferred,
        VowifiCallingMode.unknown => l10n.wfcModeUnknown,
      };
}
