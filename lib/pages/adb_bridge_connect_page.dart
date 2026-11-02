import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../services/adb_bridge_service.dart';

/// Walks a person through connecting the card over a one-time ADB session.
///
/// The app cannot open a logical channel to the card itself, but the `shell`
/// user can, and `adb shell` starts a process as `shell`. This screen shows the
/// command, opens a short window, and follows the connection as the helper
/// registers — no root and no Shizuku, just a computer for as long as the
/// session lasts.
class AdbBridgeConnectPage extends StatefulWidget {
  const AdbBridgeConnectPage({super.key});

  @override
  State<AdbBridgeConnectPage> createState() => _AdbBridgeConnectPageState();
}

class _AdbBridgeConnectPageState extends State<AdbBridgeConnectPage> {
  String _command = '';
  bool _connected = false;
  int _secondsLeft = 0;
  Timer? _countdown;
  StreamSubscription<bool>? _connectionSub;

  @override
  void initState() {
    super.initState();
    _load();
    _connectionSub = AdbBridgeService.connectionState.listen((connected) {
      if (!mounted) return;
      setState(() {
        _connected = connected;
        if (connected) _stopCountdown();
      });
    });
  }

  Future<void> _load() async {
    final command = await AdbBridgeService.connectCommand();
    final connected = await AdbBridgeService.isConnected();
    if (!mounted) return;
    setState(() {
      _command = command;
      _connected = connected;
    });
  }

  @override
  void dispose() {
    _countdown?.cancel();
    _connectionSub?.cancel();
    // Leave an open window closed if the user walks away before connecting.
    if (!_connected && _secondsLeft > 0) {
      AdbBridgeService.cancelConnect();
    }
    super.dispose();
  }

  Future<void> _startWindow() async {
    final window = await AdbBridgeService.beginConnect();
    if (!mounted) return;
    _stopCountdown();
    setState(() => _secondsLeft = window.inSeconds);
    _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _secondsLeft -= 1;
        if (_secondsLeft <= 0) {
          _secondsLeft = 0;
          timer.cancel();
        }
      });
    });
  }

  void _stopCountdown() {
    _countdown?.cancel();
    _countdown = null;
    _secondsLeft = 0;
  }

  Future<void> _copy(AppLocalizations l10n) async {
    await Clipboard.setData(ClipboardData(text: _command));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.adbBridgeCopied)));
  }

  Future<void> _disconnect() async {
    await AdbBridgeService.disconnect();
    if (!mounted) return;
    setState(() => _connected = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final windowOpen = _secondsLeft > 0;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.adbBridgeTitle)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _StatusCard(
            connected: _connected,
            windowOpen: windowOpen,
            l10n: l10n,
          ),
          const SizedBox(height: 20),
          Text(l10n.adbBridgeDescription, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              _command.isEmpty ? '…' : _command,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _command.isEmpty ? null : () => _copy(l10n),
              icon: const Icon(Icons.copy, size: 18),
              label: Text(l10n.adbBridgeCopy),
            ),
          ),
          const SizedBox(height: 24),
          if (_connected)
            FilledButton.tonalIcon(
              onPressed: _disconnect,
              icon: const Icon(Icons.link_off),
              label: Text(l10n.adbBridgeDisconnect),
            )
          else
            FilledButton.icon(
              onPressed: _startWindow,
              icon: const Icon(Icons.play_arrow),
              label: Text(
                windowOpen ? l10n.adbBridgeRestart : l10n.adbBridgeStart,
              ),
            ),
          if (windowOpen && !_connected) ...[
            const SizedBox(height: 12),
            Text(
              l10n.adbBridgeWindow(_secondsLeft),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.connected,
    required this.windowOpen,
    required this.l10n,
  });

  final bool connected;
  final bool windowOpen;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, icon, label) = connected
        ? (Colors.green, Icons.check_circle, l10n.adbBridgeConnected)
        : windowOpen
        ? (
            theme.colorScheme.primary,
            Icons.hourglass_top,
            l10n.adbBridgeWaiting,
          )
        : (
            theme.colorScheme.onSurfaceVariant,
            Icons.link_off,
            l10n.adbBridgeDisconnected,
          );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Text(
            label,
            style: theme.textTheme.titleMedium?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
