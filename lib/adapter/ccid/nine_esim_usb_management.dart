import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../utils/hex_utils.dart';
import '../euicc_adapter.dart';
import 'nine_esim_usb_protocol.dart';

class NineEsimUsbManagement {
  static Future<void> show(BuildContext context, BaseAdapter adapter) {
    return showDialog<void>(
      context: context,
      builder: (_) => _NineEsimUsbDialog(adapter: adapter),
    );
  }
}

class _NineEsimUsbDialog extends StatefulWidget {
  const _NineEsimUsbDialog({required this.adapter});

  final BaseAdapter adapter;

  @override
  State<_NineEsimUsbDialog> createState() => _NineEsimUsbDialogState();
}

class _NineEsimUsbDialogState extends State<_NineEsimUsbDialog> {
  late final TextEditingController _deviceName;
  late final TextEditingController _password;
  late final TextEditingController _atr;
  bool _euiccMode = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final readerName = widget.adapter.connectedReader?.name ?? '';
    final id = RegExp(r'([0-9A-Fa-f]{6})$').firstMatch(readerName)?.group(1);
    _deviceName = TextEditingController(text: id?.toUpperCase() ?? '');
    _password = TextEditingController();
    _atr = TextEditingController(text: NineEsimUsbProtocol.defaultAtr);
  }

  @override
  void dispose() {
    _deviceName.dispose();
    _password.dispose();
    _atr.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    setState(() => _busy = true);
    try {
      await widget.adapter.runExclusive(operation);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Writer updated')));
    } catch (error) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Update failed'),
          content: Text(error.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocalizations.of(context)!.ok),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _requireSuccess(Uint8List response) {
    final hex = HexUtils.bytesToHex(response).toUpperCase();
    if (!(hex.endsWith('9000') || hex.endsWith('6100'))) {
      throw Exception('Writer returned $hex');
    }
  }

  Future<void> _setPassword() => _run(() async {
    final response = await widget.adapter.sendRawApdu(
      NineEsimUsbProtocol.setPasswordCommand(
        deviceName: _deviceName.text,
        password: _password.text,
      ),
    );
    _requireSuccess(response);
  });

  Future<void> _setAtr() => _run(() async {
    final atr = NineEsimUsbProtocol.setEuiccCapability(_atr.text, _euiccMode);
    _atr.text = atr;
    _requireSuccess(
      await widget.adapter.sendRawApdu(
        NineEsimUsbProtocol.enableAtrProgrammingCommand(),
      ),
    );
    _requireSuccess(
      await widget.adapter.sendRawApdu(NineEsimUsbProtocol.setAtrCommand(atr)),
    );
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('9eSIM USB settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _deviceName,
              decoration: const InputDecoration(
                labelText: 'Device ID',
                hintText: '6 hex characters',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New password',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: _busy ? null : _setPassword,
                child: const Text('Set password'),
              ),
            ),
            const Divider(height: 32),
            TextField(
              controller: _atr,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'ATR',
                border: OutlineInputBorder(),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('eUICC mode'),
              subtitle: const Text(
                'Advertise eUICC-related functions in the T=15 interface bytes',
              ),
              value: _euiccMode,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _euiccMode = value),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: _busy ? null : _setAtr,
                child: const Text('Set ATR'),
              ),
            ),
            if (_busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context)!.close),
        ),
      ],
    );
  }
}
