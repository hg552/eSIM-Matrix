import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_localizations.dart';
import '../services/sms_relay_service.dart';
import '../services/remote_gateway_service.dart';
import '../widgets/styled_header_scaffold.dart';

class SmsRelayPage extends StatefulWidget {
  const SmsRelayPage({super.key});

  @override
  State<SmsRelayPage> createState() => _SmsRelayPageState();
}

class _SmsRelayPageState extends State<SmsRelayPage>
    with WidgetsBindingObserver {
  final SmsRelayService _service = const SmsRelayService();
  final TextEditingController _endpointController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _chatIdController = TextEditingController();
  final TextEditingController _activationCodeController = TextEditingController();
  final TextEditingController _confirmationCodeController = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _requestingPermission = false;
  bool _available = false;
  bool _permissionGranted = false;
  bool _enabled = false;
  bool _tokenConfigured = false;
  String _mode = SmsRelayMode.telegram;
  bool _webhookTokenConfigured = false;
  bool _telegramTokenConfigured = false;
  bool _discoveringChat = false;
  bool _testingTelegram = false;
  int? _lastDeliveryAtMillis;
  String? _lastDeliveryError;
  String? _savedChatId;
  String? _error;
  List<SmsHistoryEntry> _history = const <SmsHistoryEntry>[];
  List<Map<String, Object?>> _gatewayProfiles = const <Map<String, Object?>>[];
  String? _gatewayDefaultProfile;
  String? _gatewayApiToken;
  bool _loadingGatewayProfiles = false;
  bool _downloadingProfile = false;
  bool _runningCardOp = false;
  String? _remoteOpStatus;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _endpointController.dispose();
    _tokenController.dispose();
    _chatIdController.dispose();
    _activationCodeController.dispose();
    _confirmationCodeController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _available &&
        !_requestingPermission &&
        !_saving) {
      unawaited(_refreshStatusOnly());
    }
  }

  Future<void> _refreshStatusOnly() async {
    try {
      final permissionGranted = await _service.hasPermission();
      final configuration = await _service.loadConfiguration();
      final history = await _service.loadHistory();
      if (!mounted) return;
      setState(() {
        _permissionGranted = permissionGranted;
        _lastDeliveryAtMillis = configuration.lastDeliveryAtMillis;
        _lastDeliveryError = configuration.lastDeliveryError;
        _history = history;
        if (permissionGranted && _error == 'permission_denied') {
          _error = null;
        }
      });
    } catch (_) {}
  }
  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final available = await _service.isAvailable();
      if (!mounted) return;
      if (!available) {
        setState(() {
          _available = false;
          _loading = false;
        });
        return;
      }
      final permissionGranted = await _service.hasPermission();
      final configuration = await _service.loadConfiguration();
      final history = await _service.loadHistory();
      RemoteGatewayConfiguration? gwConfig;
      try {
        gwConfig = await _service.loadGatewayConfiguration();
      } catch (_) {}
      if (!mounted) return;
      _endpointController.text = configuration.endpoint ?? '';
      _chatIdController.text = configuration.telegramChatId ?? '';
      _savedChatId = configuration.telegramChatId;
      setState(() {
        _available = true;
        _permissionGranted = permissionGranted;
        _enabled = configuration.enabled;
        _mode = configuration.mode;
        _tokenConfigured = configuration.tokenConfigured;
        _webhookTokenConfigured = configuration.webhookTokenConfigured;
        _telegramTokenConfigured = configuration.telegramTokenConfigured;
        _lastDeliveryAtMillis = configuration.lastDeliveryAtMillis;
        _lastDeliveryError = configuration.lastDeliveryError;
        _history = history;
        _gatewayApiToken = gwConfig?.apiToken;
        _error = null;
        _loading = false;
      });
      if (_enabled || (_telegramTokenConfigured && (_savedChatId?.isNotEmpty ?? false))) {
        unawaited(RemoteGatewayService.instance.resumeIfEnabled());
      }
      unawaited(_loadGatewayProfiles());
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _error = 'settings_unavailable';
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'settings_unavailable';
        _loading = false;
      });
    }
  }

  Future<bool> _requestPermission() async {
    setState(() => _requestingPermission = true);
    try {
      final granted = await _service.requestPermission();
      if (!mounted) return granted;
      setState(() {
        _permissionGranted = granted;
        _error = granted ? null : 'permission_denied';
        _requestingPermission = false;
      });
      return granted;
    } on PlatformException {
      if (!mounted) return false;
      setState(() {
        _error = 'settings_unavailable';
        _requestingPermission = false;
      });
      return false;
    }
  }

  void _onEnabledChanged(bool enabled) {
    setState(() {
      _enabled = enabled;
      _error = null;
    });
    unawaited(_persistEnabledToggle(enabled));
    if (enabled && !_permissionGranted && !_requestingPermission) {
      unawaited(_requestPermission());
    }
  }

  Future<void> _persistEnabledToggle(bool enabled) async {
    final isTelegram = _mode == SmsRelayMode.telegram;
    final endpoint = _endpointController.text.trim();
    final telegramChatId = _chatIdController.text.trim();
    if (isTelegram && telegramChatId.isEmpty) return;
    if (!isTelegram && !SmsRelayService.isSecureEndpoint(endpoint)) return;
    try {
      await _service.saveConfiguration(
        mode: _mode,
        endpoint: isTelegram ? null : endpoint,
        telegramChatId: isTelegram ? telegramChatId : null,
        token: _tokenController.text,
        enabled: enabled,
      );
      if (enabled || (_telegramTokenConfigured && telegramChatId.isNotEmpty)) {
        unawaited(RemoteGatewayService.instance.resumeIfEnabled());
      }
    } catch (_) {}
  }
  void _onModeChanged(String? mode) {
    if (mode == null || mode == _mode) return;
    _tokenController.clear();
    setState(() {
      _mode = mode;
      _tokenConfigured = mode == SmsRelayMode.telegram
          ? _telegramTokenConfigured
          : _webhookTokenConfigured;
      _error = null;
    });
  }

  Future<void> _discoverTelegramChat() async {
    final l10n = AppLocalizations.of(context)!;
    if (_tokenController.text.trim().isEmpty && !_telegramTokenConfigured) {
      setState(() => _error = 'token_required');
      return;
    }
    setState(() {
      _discoveringChat = true;
      _error = null;
    });
    try {
      final chat = await _service.discoverTelegramChat(
        token: _tokenController.text.trim(),
      );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.smsRelayConfirmPrivateChat),
          content: Text(
            l10n.smsRelayDiscoveredPrivateChat(chat.displayName, chat.chatId),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.smsRelayUsePrivateChat),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        _chatIdController.text = chat.chatId;
        setState(() => _error = null);
      }
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = _platformError(error.code));
    } catch (_) {
      if (mounted) setState(() => _error = 'telegram_request_failed');
    } finally {
      if (mounted) setState(() => _discoveringChat = false);
    }
  }

  Future<void> _testTelegram() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _testingTelegram = true;
      _error = null;
    });
    try {
      await _service.testTelegram();
      final history = await _service.loadHistory();
      if (mounted) {
        setState(() => _history = history);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.smsRelayTelegramTestSent)));
      }
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = _platformError(error.code));
    } catch (_) {
      if (mounted) setState(() => _error = 'telegram_request_failed');
    } finally {
      if (mounted) setState(() => _testingTelegram = false);
    }
  }

  String _platformError(String code) => switch (code) {
    'invalid_endpoint' || 'https_required' => 'invalid_endpoint',
    'token_required' || 'telegram_config_required' => 'token_required',
    'invalid_chat_id' => 'invalid_chat_id',
    'private_chat_not_found' => 'private_chat_not_found',
    'permission_required' => 'permission_required',
    'invalid_bot_token' ||
    'telegram_api_error' ||
    'telegram_api_rejected' ||
    'telegram_invalid_response' ||
    'telegram_network_error' ||
    'telegram_response_too_large' ||
    'telegram_transport_error' ||
    'telegram_unavailable' => 'telegram_request_failed',
    _ => 'settings_unavailable',
  };

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final isTelegram = _mode == SmsRelayMode.telegram;
    final endpoint = _endpointController.text.trim();
    final telegramChatId = _chatIdController.text.trim();
    if (!isTelegram && !SmsRelayService.isSecureEndpoint(endpoint)) {
      setState(() => _error = 'invalid_endpoint');
      return;
    }
    if (isTelegram && telegramChatId.isEmpty) {
      setState(() => _error = 'invalid_chat_id');
      return;
    }
    if (isTelegram && telegramChatId != _savedChatId) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.smsRelayConfirmPrivateChat),
          content: Text('${l10n.smsRelayPrivacy}\n\nChat ID: $telegramChatId'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.save)),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    if (_enabled && !_permissionGranted) {
      if (!await _requestPermission()) return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _service.saveConfiguration(
        mode: _mode,
        endpoint: isTelegram ? null : endpoint,
        telegramChatId: isTelegram ? telegramChatId : null,
        token: _tokenController.text,
        enabled: _enabled,
      );
      _tokenController.clear();
      await _load();
      if (_enabled || (_telegramTokenConfigured && (_savedChatId?.isNotEmpty ?? false))) {
        unawaited(RemoteGatewayService.instance.resumeIfEnabled());
      } else {
        unawaited(RemoteGatewayService.instance.stop());
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.smsRelaySaved)));
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _error = _platformError(error.code));
    } catch (_) {
      if (mounted) setState(() => _error = 'settings_unavailable');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearToken() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.smsRelayClearToken),
        content: Text(l10n.smsRelayClearTokenConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.smsRelayForgetToken),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _service.clearToken();
      _tokenController.clear();
      await _load();
      unawaited(RemoteGatewayService.instance.stop());
    } on PlatformException {
      if (mounted) setState(() => _error = 'settings_unavailable');
    }
  }

  String _errorMessage(AppLocalizations l10n) => switch (_error) {
    'invalid_endpoint' => l10n.smsRelayInvalidEndpoint,
    'token_required' =>
      _mode == SmsRelayMode.telegram
          ? l10n.smsRelayBotTokenRequired
          : l10n.smsRelayTokenRequired,
    'invalid_chat_id' => l10n.smsRelayInvalidPrivateChat,
    'private_chat_not_found' => l10n.smsRelayPrivateChatNotFound,
    'telegram_request_failed' => l10n.smsRelayTelegramRequestFailed,
    'permission_required' ||
    'permission_denied' => l10n.smsRelayPermissionDenied,
    _ => l10n.smsRelaySettingsFailed,
  };

  String _deliveryLabel(AppLocalizations l10n) {
    if (_lastDeliveryError != null) {
      return l10n.smsRelayDeliveryFailed(_lastDeliveryError!);
    }
    final deliveredAt = _lastDeliveryAtMillis;
    if (deliveredAt == null) return l10n.smsRelayNoDelivery;
    final time = DateTime.fromMillisecondsSinceEpoch(
      deliveredAt,
    ).toLocal().toString();
    return l10n.smsRelayLastDelivery(time);
  }

  void _openSettings() {
    unawaited(openAppSettings());
  }

  Widget _buildPermissionCard(AppLocalizations l10n) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.smsRelayPermissionRequired,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(l10n.smsRelayPermissionHelp),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _requestingPermission ? null : _requestPermission,
                  icon: const Icon(Icons.sms_outlined),
                  label: Text(l10n.smsRelayGrantPermission),
                ),
                TextButton(
                  onPressed: _openSettings,
                  child: Text(l10n.openSettings),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUnavailableCard(AppLocalizations l10n) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(l10n.smsRelayUnavailable),
      ),
    );
  }

  Future<void> _refreshHistory() async {
    try {
      final history = await _service.loadHistory();
      final configuration = await _service.loadConfiguration();
      if (!mounted) return;
      setState(() {
        _history = history;
        _lastDeliveryAtMillis = configuration.lastDeliveryAtMillis;
        _lastDeliveryError = configuration.lastDeliveryError;
      });
    } catch (_) {}
  }

  Future<void> _deleteHistoryItem(String id) async {
    try {
      await _service.deleteHistoryItem(id);
      await _refreshHistory();
    } catch (_) {}
  }

  Future<void> _retryFailedHistory({String? id}) async {
    try {
      final count = await _service.retryFailedHistory(id: id);
      await _refreshHistory();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              count > 0 ? '✅ 已成功补发 $count 条短信' : '⚠️ 补发未成功，请检查网络或 Bot 配置',
            ),
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _clearAllHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空短信转发记录'),
        content: const Text('确定要删除所有本地保存的历史短信转发记录吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _service.clearHistory();
      await _refreshHistory();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已清空所有历史短信记录')),
        );
      }
    } catch (_) {}
  }

  Future<void> _loadGatewayProfiles() async {
    if (_loadingGatewayProfiles) return;
    if (mounted) setState(() => _loadingGatewayProfiles = true);
    try {
      final st = await RemoteGatewayService.instance.status();
      final list = await RemoteGatewayService.instance.listProfiles();
      final gwConfig = await _service.loadGatewayConfiguration();
      if (!mounted) return;
      setState(() {
        _gatewayProfiles = list;
        _gatewayDefaultProfile = st['defaultProfile'] as String?;
        _gatewayApiToken = gwConfig.apiToken;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingGatewayProfiles = false);
    }
  }

  Future<void> _downloadProfileFromUi({String? overrideCode}) async {
    final code = (overrideCode ?? _activationCodeController.text).trim();
    final cc = _confirmationCodeController.text.trim();
    if (code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先输入 LPA:1\$... 激活码')),
      );
      return;
    }
    setState(() {
      _downloadingProfile = true;
      _remoteOpStatus = '⏳ 正在连接 SM-DP+ 服务器下载并写入 eUICC 芯片（约需 15~45 秒）...';
    });
    try {
      final res = await RemoteGatewayService.instance.downloadProfile(
        code,
        confirmationCode: cc.isEmpty ? null : cc,
        onStatus: (msg) {
          if (mounted) setState(() => _remoteOpStatus = '⏳ $msg');
        },
      );
      if (!mounted) return;
      if (overrideCode == null) {
        _activationCodeController.clear();
        _confirmationCodeController.clear();
      }
      setState(() {
        _remoteOpStatus = '✅ 下卡成功！ICCID: ${res['iccid'] ?? ''}';
      });
      await _loadGatewayProfiles();
    } catch (e) {
      if (mounted) {
        setState(() => _remoteOpStatus = '❌ 下卡失败: $e');
      }
    } finally {
      if (mounted) setState(() => _downloadingProfile = false);
    }
  }

  Future<void> _switchProfileFromUi(String iccid, String alias) async {
    setState(() {
      _runningCardOp = true;
      _remoteOpStatus = '⚡ 正在切换至【$alias】...';
    });
    try {
      await RemoteGatewayService.instance.switchProfile(iccid);
      if (!mounted) return;
      setState(() {
        _remoteOpStatus = '🔄 已切换至【$alias】，正在等待基带漫游搜网驻留...';
      });
      await _loadGatewayProfiles();
    } catch (e) {
      if (mounted) {
        setState(() => _remoteOpStatus = '❌ 切卡失败: $e');
      }
    } finally {
      if (mounted) setState(() => _runningCardOp = false);
    }
  }

  Future<void> _setDefaultFromUi() async {
    setState(() => _runningCardOp = true);
    try {
      final res = await RemoteGatewayService.instance.setDefaultProfile();
      if (!mounted) return;
      setState(() {
        _gatewayDefaultProfile = res['defaultProfile'] as String?;
        _remoteOpStatus = '✅ 已将【${res['defaultProfile']}】设为默认回滚主卡';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _remoteOpStatus = '❌ 设定默认主卡失败: $e');
      }
    } finally {
      if (mounted) setState(() => _runningCardOp = false);
    }
  }

  Future<void> _deleteProfileFromUi(String iccid, String alias) async {
    setState(() => _runningCardOp = true);
    try {
      final req = await RemoteGatewayService.instance.requestDeleteProfile(iccid);
      final token = '${req['token'] ?? ''}';
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('⚠️ 确认永久删除 eSIM 卡片'),
          content: Text(
            '即将从物理 eUICC 芯片中彻底抹除以下卡片：\n\n'
            '• 名称：$alias\n'
            '• ICCID：$iccid\n'
            '• 安全确认码：$token\n\n'
            '删除后不可撤销（系统将自动向运营商服务器发送删除通知以释放二维码）。确定继续吗？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认彻底删除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _remoteOpStatus = '⏳ 正在从芯片抹除【$alias】并同步通知服务器...');
      await RemoteGatewayService.instance.confirmDeleteProfile(token);
      if (!mounted) return;
      setState(() => _remoteOpStatus = '🗑️ 已成功删除卡片【$alias】');
      await _loadGatewayProfiles();
    } catch (e) {
      if (mounted) {
        setState(() => _remoteOpStatus = '❌ 删卡失败: $e');
      }
    } finally {
      if (mounted) setState(() => _runningCardOp = false);
    }
  }

  String _formatHistoryTime(int millis) {
    if (millis <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  Widget _buildHistoryCard(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history_edu_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '历史短信转发记录 (${_history.length})',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _refreshHistory,
                  tooltip: '刷新记录',
                  icon: const Icon(Icons.refresh, size: 20),
                ),
                if (_history.isNotEmpty)
                  TextButton.icon(
                    onPressed: _clearAllHistory,
                    icon: Icon(
                      Icons.delete_sweep_outlined,
                      size: 18,
                      color: theme.colorScheme.error,
                    ),
                    label: Text(
                      '清空',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _deliveryLabel(l10n),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_history.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '暂无短信转发记录。当收到新短信或点击上方“发送测试消息”后，此处将显示完整的短信内容、发件号码与接收卡槽。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _history.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final item = _history[index];
                  final slotLabel = item.slotIndex != null ? 'SIM ${item.slotIndex! + 1}' : null;
                  final originParts = <String>[
                    if (slotLabel != null) slotLabel,
                    if (item.carrierName != null) item.carrierName!,
                  ];
                  final originText = originParts.isEmpty ? '本机接收' : originParts.join(' · ');
                  final statusText = item.delivered
                      ? '已转发 (${item.mode == SmsRelayMode.telegram ? "Telegram" : "Webhook"})'
                      : '失败 (${item.errorCode ?? "error"})';
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: item.delivered
                            ? theme.colorScheme.outlineVariant.withValues(alpha: 0.5)
                            : theme.colorScheme.error.withValues(alpha: 0.6),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '发件人: ${item.sender}',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: item.delivered
                                    ? Colors.green.withValues(alpha: 0.18)
                                    : theme.colorScheme.errorContainer,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                statusText,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: item.delivered
                                      ? Colors.greenAccent.shade200
                                      : theme.colorScheme.onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$originText · ${_formatHistoryTime(item.receivedAtMillis)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: SelectableText(
                            item.body,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 4,
                          children: [
                            if (item.otp != null && item.otp!.isNotEmpty)
                              FilledButton.tonalIcon(
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: item.otp!));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('已复制验证码: ${item.otp}')),
                                  );
                                },
                                icon: const Icon(Icons.key_outlined, size: 15),
                                label: Text('复制验证码 ${item.otp}'),
                              ),
                            if (!item.delivered)
                              TextButton.icon(
                                onPressed: () => _retryFailedHistory(id: item.id),
                                icon: const Icon(Icons.refresh, size: 16),
                                label: const Text('重发'),
                              ),
                            TextButton.icon(
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: item.body));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('已复制短信内容')),
                                );
                              },
                              icon: const Icon(Icons.copy_outlined, size: 16),
                              label: const Text('复制全文'),
                            ),
                            TextButton.icon(
                              onPressed: () => _deleteHistoryItem(item.id),
                              icon: Icon(
                                Icons.delete_outline,
                                size: 16,
                                color: theme.colorScheme.error,
                              ),
                              label: Text(
                                '删除',
                                style: TextStyle(color: theme.colorScheme.error),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRemoteOpsCard() {
    final theme = Theme.of(context);
    final gateway = RemoteGatewayService.instance;
    final apiUrl = gateway.apiUrl;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_sync_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '远程下卡 / 切卡 / 删卡控制中心',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _loadingGatewayProfiles ? null : _loadGatewayProfiles,
                  tooltip: '刷新卡内列表与网关状态',
                  icon: _loadingGatewayProfiles
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              gateway.isRunning
                  ? '🟢 网关运行中 · Web 面板: ${apiUrl ?? "http://127.0.0.1:8787/"}'
                  : '⚪ 网关待命（保存上方配置后自动启动）',
              style: theme.textTheme.bodySmall,
            ),
            if (apiUrl != null || (_gatewayApiToken?.isNotEmpty ?? false)) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (apiUrl != null)
                    OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: apiUrl));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已复制 Web 面板地址: $apiUrl')),
                        );
                      },
                      icon: const Icon(Icons.link, size: 16),
                      label: const Text('复制 Web 面板地址'),
                    ),
                  if (_gatewayApiToken != null && _gatewayApiToken!.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _gatewayApiToken!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制 Web Bearer Token')),
                        );
                      },
                      icon: const Icon(Icons.key_outlined, size: 16),
                      label: const Text('复制 Web Token'),
                    ),
                ],
              ),
            ],
            const Divider(height: 24),
            Text(
              '📥 远程 / 快捷下卡 (Download eSIM)',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _activationCodeController,
              enabled: !_downloadingProfile,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'LPA 激活码 (LPA:1\$smdp.address\$matchingId)',
                hintText: 'LPA:1\$rsp.truphone.com\$QRF-SPEEDTEST',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _confirmationCodeController,
              enabled: !_downloadingProfile,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '确认码 Confirmation Code（选填）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _downloadingProfile ? null : _downloadProfileFromUi,
                  icon: _downloadingProfile
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: const Text('立即下载安装 eSIM'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _downloadingProfile
                      ? null
                      : () {
                          _activationCodeController.text =
                              'LPA:1\$rsp.truphone.com\$QRF-SPEEDTEST';
                          _downloadProfileFromUi(
                            overrideCode: 'LPA:1\$rsp.truphone.com\$QRF-SPEEDTEST',
                          );
                        },
                  icon: const Icon(Icons.rocket_launch_outlined),
                  label: const Text('一键下载 Speedtest 公开测试 eSIM'),
                ),
                OutlinedButton.icon(
                  onPressed: _downloadingProfile
                      ? null
                      : () {
                          _activationCodeController.text =
                              'LPA:1\$rsp.truphone.com\$QRF-SPEEDTEST';
                        },
                  icon: const Icon(Icons.edit_note_outlined),
                  label: const Text('填入 Speedtest 激活码'),
                ),
              ],
            ),
            if (_remoteOpStatus != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _remoteOpStatus!,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '🗂️ 卡内 Profile 列表与安全删卡 (${_gatewayProfiles.length})',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  onPressed: _loadingGatewayProfiles ? null : _loadGatewayProfiles,
                  icon: const Icon(Icons.sim_card_outlined, size: 16),
                  label: const Text('读取卡内列表'),
                ),
              ],
            ),
            if (_gatewayDefaultProfile != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '🏠 当前默认回滚主卡: $_gatewayDefaultProfile',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            if (_gatewayProfiles.isEmpty)
              Text(
                '点击右上角“读取卡内列表”加载当前 eUICC 中的所有 Profile（也可直接在 Telegram 发送 /list、/download、/delete 操作）。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _gatewayProfiles.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final p = _gatewayProfiles[index];
                  final iccid = '${p['iccid'] ?? ''}';
                  final alias = '${p['alias'] ?? iccid}';
                  final suffix = '${p['iccidSuffix'] ?? ''}';
                  final active = p['enabled'] == true;
                  return Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '[${index + 1}] ${active ? "🟢 " : "⚪ "}$alias',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '尾号 $suffix · ${active ? "当前激活中" : "未启用"}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (active)
                          OutlinedButton(
                            onPressed: _runningCardOp ? null : _setDefaultFromUi,
                            child: const Text('设为主卡'),
                          )
                        else ...[
                          OutlinedButton(
                            onPressed: _runningCardOp
                                ? null
                                : () => _switchProfileFromUi(iccid, alias),
                            child: const Text('启用'),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            tooltip: '删除此卡片（二步确认）',
                            onPressed: _runningCardOp
                                ? null
                                : () => _deleteProfileFromUi(iccid, alias),
                            icon: Icon(
                              Icons.delete_forever_outlined,
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            const Divider(height: 24),
            Text(
              '🤖 Telegram 远程下卡 / 删卡 / 切卡指令（点击可复制）：',
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final cmd in const [
                  ('/help', '📋 帮助菜单 (/help)'),
                  ('/list', '🗂️ 查卡列表 (/list)'),
                  ('/status', '📡 基带状态 (/status)'),
                  ('/use 1', '🔄 切卡 (/use <序号>)'),
                  ('/back', '🏠 切回主卡 (/back)'),
                  ('/default', '📌 设为主卡 (/default)'),
                  ('/download LPA:1\$', '📥 远程下卡 (/download)'),
                  ('/download_test', '🚀 下测试卡 (/download_test)'),
                  ('/delete 2', '🗑️ 远程删卡 (/delete <序号>)'),
                ])
                  ActionChip(
                    label: Text(cmd.$2, style: theme.textTheme.labelSmall),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: cmd.$1));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已复制 Telegram 指令: ${cmd.$1}')),
                      );
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return StyledHeaderScaffold(
      title: l10n.smsRelayTitle,
      subtitle: l10n.smsRelaySubtitle,
      showBackButton: false,
      actions: [
        IconButton(
          onPressed: _loading ? null : _load,
          tooltip: l10n.refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: ListView(
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
                  Expanded(child: Text(l10n.smsRelayPrivacy)),
                ],
              ),
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (!_available)
            _buildUnavailableCard(l10n)
          else ...[
            if (!_permissionGranted) _buildPermissionCard(l10n),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.smsRelayForwardingEnabled),
                      value: _enabled,
                      onChanged: _onEnabledChanged,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _mode,
                      decoration: InputDecoration(
                        labelText: l10n.smsRelayDestination,
                        border: const OutlineInputBorder(),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: SmsRelayMode.webhook,
                          child: Text(l10n.smsRelayWebhook),
                        ),
                        DropdownMenuItem(
                          value: SmsRelayMode.telegram,
                          child: Text(l10n.smsRelayTelegram),
                        ),
                      ],
                      onChanged: _saving ? null : _onModeChanged,
                    ),
                    if (_mode == SmsRelayMode.webhook) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _endpointController,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: l10n.smsRelayEndpoint,
                          hintText: l10n.smsRelayEndpointHint,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(l10n.smsRelayTelegramSetupHelp),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: _tokenController,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: _mode == SmsRelayMode.telegram
                            ? l10n.smsRelayBotToken
                            : l10n.smsRelayToken,
                        hintText: _tokenConfigured
                            ? l10n.smsRelayTokenHint
                            : null,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    if (_tokenConfigured) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _mode == SmsRelayMode.telegram
                              ? l10n.smsRelayTelegramTokenStored
                              : l10n.smsRelayTokenStored,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                    if (_mode == SmsRelayMode.telegram) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _chatIdController,
                        readOnly: _saving,
                        keyboardType: const TextInputType.numberWithOptions(signed: true),
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: l10n.smsRelayPrivateChat,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _saving || _discoveringChat
                                ? null
                                : _discoverTelegramChat,
                            icon: _discoveringChat
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.person_search_outlined),
                            label: Text(l10n.smsRelayFindPrivateChat),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                _saving ||
                                    _testingTelegram ||
                                    !_telegramTokenConfigured ||
                                    _chatIdController.text.isEmpty
                                ? null
                                : _testTelegram,
                            icon: _testingTelegram
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.send_outlined),
                            label: Text(l10n.smsRelayTestTelegram),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _saving ? null : _save,
                            icon: _saving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.save_outlined),
                            label: Text(l10n.smsRelaySave),
                          ),
                        ),
                        if (_tokenConfigured) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: l10n.smsRelayForgetToken,
                            onPressed: _saving ? null : _clearToken,
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_errorMessage(l10n)),
                ),
              ),
            ],
            const SizedBox(height: 12),
            _buildHistoryCard(l10n),
            const SizedBox(height: 12),
            _buildRemoteOpsCard(),
          ],
        ],
      ),
    );
  }
}
