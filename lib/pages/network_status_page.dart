import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_localizations.dart';
import '../services/network_status_service.dart';
import '../widgets/styled_header_scaffold.dart';

class NetworkStatusPage extends StatefulWidget {
  const NetworkStatusPage({super.key});

  @override
  State<NetworkStatusPage> createState() => _NetworkStatusPageState();
}

class _NetworkStatusPageState extends State<NetworkStatusPage>
    with WidgetsBindingObserver {
  final NetworkStatusService _service = const NetworkStatusService();
  StreamSubscription<NetworkStatusUpdate>? _updates;
  List<NetworkStatusSubscription> _subscriptions = const [];
  bool _checkingAvailability = true;
  bool _checkingPermission = false;
  bool _supported = false;
  bool _permissionGranted = false;
  bool _permissionPermanentlyDenied = false;
  bool _loadingStatus = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAvailability();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopListening());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _supported) {
      _checkPermission();
    } else if (state == AppLifecycleState.paused) {
      unawaited(_stopListening());
    }
  }

  Future<void> _checkAvailability() async {
    try {
      final supported = await _service.isSupported();
      if (!mounted) return;
      setState(() {
        _supported = supported;
        _checkingAvailability = false;
      });
      if (supported) await _checkPermission();
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _checkingAvailability = false;
        _error = 'telephony_unavailable';
      });
    }
  }

  Future<void> _checkPermission() async {
    try {
      final status = await Permission.phone.status;
      if (!mounted) return;
      setState(() {
        _permissionGranted = status.isGranted;
        _permissionPermanentlyDenied = status.isPermanentlyDenied;
        _checkingPermission = false;
        if (!status.isGranted) {
          _subscriptions = const [];
          _error = null;
          _loadingStatus = false;
        }
      });
      if (status.isGranted) {
        _startListening();
      } else {
        await _stopListening();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checkingPermission = false;
        _error = 'telephony_unavailable';
      });
    }
  }

  Future<void> _requestPermission() async {
    setState(() => _checkingPermission = true);
    try {
      final status = await Permission.phone.request();
      if (!mounted) return;
      setState(() {
        _permissionGranted = status.isGranted;
        _permissionPermanentlyDenied = status.isPermanentlyDenied;
        _checkingPermission = false;
      });
      if (status.isGranted) {
        _startListening();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checkingPermission = false;
        _error = 'telephony_unavailable';
      });
    }
  }

  void _openSettings() {
    unawaited(openAppSettings());
  }

  void _startListening() {
    if (_updates != null || !_permissionGranted) return;
    setState(() {
      _loadingStatus = true;
      _error = null;
    });
    _updates = _service.updates.listen(
      _handleUpdate,
      onError: _handleStreamError,
    );
    unawaited(_refreshStatus());
  }

  Future<void> _stopListening() async {
    final updates = _updates;
    _updates = null;
    await updates?.cancel();
  }

  Future<void> _refreshStatus() async {
    if (!_permissionGranted || _updates == null) return;
    setState(() => _loadingStatus = true);
    try {
      await _service.refresh();
    } on PlatformException catch (error) {
      _handleStreamError(error);
    }
  }

  void _handleUpdate(NetworkStatusUpdate update) {
    if (!mounted) return;
    setState(() {
      _subscriptions = update.subscriptions;
      _error = update.error;
      _loadingStatus = false;
    });
  }

  void _handleStreamError(Object error) {
    if (!mounted) return;
    setState(() {
      _error = error is PlatformException
          ? error.code
          : 'telephony_unavailable';
      _loadingStatus = false;
    });
  }

  String _errorMessage(AppLocalizations l10n, String? code) => switch (code) {
    'unsupported' => l10n.networkStatusUnsupported,
    'permission_required' => l10n.networkStatusPermissionRequired,
    _ => l10n.networkStatusUnavailable,
  };

  String _registrationLabel(
    AppLocalizations l10n,
    VoiceRegistrationState state,
  ) => switch (state) {
    VoiceRegistrationState.inService => l10n.networkStatusInService,
    VoiceRegistrationState.outOfService => l10n.networkStatusOutOfService,
    VoiceRegistrationState.emergencyOnly => l10n.networkStatusEmergencyOnly,
    VoiceRegistrationState.radioOff => l10n.networkStatusRadioOff,
    VoiceRegistrationState.unknown => l10n.unknown,
  };

  Widget _buildPermissionCard(AppLocalizations l10n) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.networkStatusPermissionRequired,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(l10n.networkStatusPermissionMessage),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _checkingPermission
                  ? null
                  : _permissionPermanentlyDenied
                  ? _openSettings
                  : _requestPermission,
              icon: const Icon(Icons.phonelink_lock_outlined),
              label: Text(
                _permissionPermanentlyDenied
                    ? l10n.openSettings
                    : l10n.networkStatusGrantPermission,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageCard(String message) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }

  Widget _buildSubscriptionCard(
    AppLocalizations l10n,
    NetworkStatusSubscription subscription,
  ) {
    final displayName = subscription.displayName?.trim();
    final carrierName = subscription.carrierName?.trim();
    final title = displayName != null && displayName.isNotEmpty
        ? displayName
        : carrierName != null && carrierName.isNotEmpty
        ? carrierName
        : l10n.networkStatusSubscription;
    final slot = subscription.slotIndex >= 0
        ? l10n.networkStatusSlot(subscription.slotIndex + 1)
        : l10n.unknown;
    final signalParts = <String>[];
    if (subscription.signalDbm != null) {
      signalParts.add('${subscription.signalDbm} dBm');
    }
    if (subscription.signalLevel != null) {
      signalParts.add('${subscription.signalLevel}/4');
    }
    final signal = signalParts.isEmpty ? l10n.unknown : signalParts.join(' · ');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.sim_card_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(slot, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            if (carrierName != null && carrierName.isNotEmpty) ...[
              const SizedBox(height: 12),
              _NetworkStatusRow(
                label: l10n.networkStatusCarrier,
                value: carrierName,
              ),
            ],
            const Divider(height: 24),
            _NetworkStatusRow(
              label: l10n.networkStatusVoiceRegistration,
              value: subscription.error == null
                  ? _registrationLabel(
                      l10n,
                      subscription.voiceRegistrationState,
                    )
                  : _errorMessage(l10n, subscription.error),
            ),
            _NetworkStatusRow(
              label: l10n.networkStatusRoaming,
              value: subscription.roaming == null
                  ? l10n.unknown
                  : subscription.roaming!
                  ? l10n.networkStatusYes
                  : l10n.networkStatusNo,
            ),
            _NetworkStatusRow(label: l10n.networkStatusSignal, value: signal),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return StyledHeaderScaffold(
      title: l10n.networkStatusTitle,
      subtitle: l10n.networkStatusSubtitle,
      showBackButton: false,
      actions: [
        IconButton(
          onPressed: _permissionGranted && !_loadingStatus
              ? _refreshStatus
              : null,
          tooltip: l10n.refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: RefreshIndicator(
        onRefresh: _refreshStatus,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.privacy_tip_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(l10n.networkStatusPrivacy)),
                  ],
                ),
              ),
            ),
            if (_checkingAvailability || _checkingPermission)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (!_supported)
              _buildMessageCard(l10n.networkStatusUnsupported)
            else if (!_permissionGranted)
              _buildPermissionCard(l10n)
            else if (_error != null)
              _buildMessageCard(_errorMessage(l10n, _error))
            else if (_loadingStatus && _subscriptions.isEmpty)
              _buildMessageCard(l10n.networkStatusWaiting)
            else if (_subscriptions.isEmpty)
              _buildMessageCard(l10n.networkStatusNoSubscriptions)
            else ...[
              for (final subscription in _subscriptions)
                _buildSubscriptionCard(l10n, subscription),
            ],
            if (_supported && _permissionGranted) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  l10n.networkStatusLimits,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NetworkStatusRow extends StatelessWidget {
  const _NetworkStatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
