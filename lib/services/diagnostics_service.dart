import 'dart:async';
import 'package:logging/logging.dart';

import '../adapter/composite_adapter.dart';
import '../adapter/discovery_report.dart';
import '../adapter/omapi/omapi_adapter.dart';
import '../config.dart';
import '../settings/app_settings.dart';
import '../utils/platform_adapter.dart';
import '../version.dart';
import 'log_buffer.dart';

/// One actionable observation derived from the diagnostic snapshot.
enum DiagnosticSeverity { info, warning, error }

class DiagnosticHint {
  const DiagnosticHint({
    required this.severity,
    required this.titleEn,
    required this.titleZh,
    this.detailEn,
    this.detailZh,
    this.actionZh,
  });

  final DiagnosticSeverity severity;
  final String titleEn;
  final String titleZh;
  final String? detailEn;
  final String? detailZh;
  final String? actionZh;

  String get severityEmoji => switch (severity) {
    DiagnosticSeverity.error => '❌',
    DiagnosticSeverity.warning => '⚠️',
    DiagnosticSeverity.info => 'ℹ️',
  };

  String toPlainString() {
    final buf = StringBuffer('$severityEmoji [$titleZh / $titleEn]');
    if (detailZh != null || detailEn != null) {
      buf.write('\n   原因: ${detailZh ?? detailEn}');
      if (detailEn != null && detailZh != null) {
        buf.write(' ($detailEn)');
      }
    }
    if (actionZh != null) {
      buf.write('\n   👉 建议: $actionZh');
    }
    return buf.toString();
  }
}

/// Complete diagnostic snapshot ready to copy or display.
class DiagnosticsSnapshot {
  const DiagnosticsSnapshot({
    required this.at,
    required this.hints,
    required this.reportText,
    required this.totalReaders,
    required this.omapiConnected,
    required this.omapiPoisoned,
  });

  final DateTime at;
  final List<DiagnosticHint> hints;
  final String reportText;
  final int totalReaders;
  final bool omapiConnected;
  final bool omapiPoisoned;
}

class DiagnosticsService {
  /// Identifier runs that start with 89 are ICCIDs or EIDs. They are matched
  /// without a word boundary so the value is still caught when it sits inside a
  /// longer hex blob — an APDU value of tag 5A, for instance, has hex on both
  /// sides and `\b` never fires there.
  static final RegExp _idRunRegex = RegExp(
    r'(89[0-9]{2})[0-9a-fA-F]{10,30}([0-9a-fA-F]{4})',
  );
  static final RegExp _botTokenRegex = RegExp(r'\b\d{8,11}:[A-Za-z0-9_-]{35}\b');

  /// Credentials embedded in a URL, as the remote-card settings store them
  /// (`http://:<password>@host:port`).
  static final RegExp _urlCredentialRegex = RegExp(r'://[^/\s@]+@');

  /// Bluetooth reader addresses identify hardware; keep the vendor prefix only.
  static final RegExp _macRegex = RegExp(
    r'\b([0-9A-Fa-f]{2})(?::[0-9A-Fa-f]{2}){5}\b',
  );

  /// Redacts identifiers, credentials and tokens before a report is shared.
  ///
  /// This is applied to the whole report as a final pass, not just to the log
  /// tail: reader ids, telephony strings and exception messages carry the same
  /// material and used to reach the clipboard untouched.
  static String redact(String input) {
    var s = input;
    s = s.replaceAllMapped(_urlCredentialRegex, (_) => '://***@');
    s = s.replaceAllMapped(_idRunRegex, (m) => '${m[1]}...${m[2]} [ID masked]');
    s = s.replaceAllMapped(_botTokenRegex, (_) => '[BOT_TOKEN_REDACTED]');
    s = s.replaceAllMapped(_macRegex, (m) => '${m[1]}:**:**:**:**:**');
    return s;
  }

  /// Derives actionable hints from the collected native and discovery data.
  static List<DiagnosticHint> deriveHints({
    required ReaderDiscoveryReport? discovery,
    required Map<String, dynamic> native,
    required AppSettings settings,
  }) {
    final hints = <DiagnosticHint>[];

    final device = (native['device'] is Map)
        ? Map<String, dynamic>.from(native['device'] as Map)
        : const <String, dynamic>{};
    final telephony = (native['telephony'] is Map)
        ? Map<String, dynamic>.from(native['telephony'] as Map)
        : const <String, dynamic>{};
    final se = (native['se'] is Map)
        ? Map<String, dynamic>.from(native['se'] as Map)
        : const <String, dynamic>{};

    final isAndroid = PlatformX.isAndroid ||
        native.containsKey('device') ||
        native.containsKey('se') ||
        (device['sdkInt'] as int? ?? 0) > 0;
    final sdkInt = device['sdkInt'] as int? ?? (isAndroid ? 34 : 0);
    final omapiEnabled = settings.enableOmapiConnector;
    final poison = se['poison']?.toString();
    final serviceCreated = se['serviceCreated'] == true;
    final serviceConnected = se['serviceConnected'] == true;
    final featureOmapiUicc = device['featureOmapiUicc'];
    final rawReaders = (se['readers'] as List?) ?? const [];

    // 1. Android version check
    if (isAndroid && sdkInt > 0 && sdkInt < 28) {
      hints.add(
        DiagnosticHint(
          severity: DiagnosticSeverity.error,
          titleEn: 'Android version below 9.0 (API 28)',
          titleZh: '系统版本低于 Android 9.0',
          detailEn: 'Android OMAPI requires API level 28+. Handset SIM OMAPI cannot work on this device.',
          detailZh: 'Android 系统原生 OMAPI 接口在 Android 9 (API 28) 才正式引入，无法通过内置卡槽管理 eSIM。',
          actionZh: '请使用 ESTKme 官方独立 App，或搭配外置 USB/蓝牙读卡器使用。',
        ),
      );
    }

    // 2. OMAPI connector switch is OFF
    if (isAndroid && !omapiEnabled) {
      hints.add(
        DiagnosticHint(
          severity: DiagnosticSeverity.error,
          titleEn: 'Built-in OMAPI is disabled in settings',
          titleZh: '设置中内置 OMAPI 读卡器已关闭',
          detailEn: 'The app will not query handset SIM slots via OMAPI.',
          detailZh: '应用不会通过系统 OMAPI 接口读取手机卡槽。',
          actionZh: '请前往「设置」->「读卡器类型」，将「内置 OMAPI」开关打开后下拉刷新。',
        ),
      );
    }

    // 3. OMAPI poisoned
    if (poison != null && poison.isNotEmpty) {
      hints.add(
        DiagnosticHint(
          severity: DiagnosticSeverity.error,
          titleEn: 'OMAPI session corrupted (poisoned)',
          titleZh: 'OMAPI 安全元件会话已损坏 (Poisoned)',
          detailEn: poison,
          detailZh: '底层安全元件会话出现异常或系统级挂起: $poison',
          actionZh: '必须完全重启手机（Reboot）方可重置 Android 系统 SE 服务。',
        ),
      );
    }

    // 4. SEService connection failed
    if (isAndroid && omapiEnabled && sdkInt >= 28 && poison == null) {
      if (!serviceCreated) {
        hints.add(
          DiagnosticHint(
            severity: DiagnosticSeverity.warning,
            titleEn: 'SEService instance not created',
            titleZh: '系统 SE 服务实例未创建',
            detailEn: se['lifecycle']?.toString() ?? 'Activity attach or background lifecycle issue.',
            detailZh: 'OMAPI 插件未能成功绑定当前 Activity 或后台生命周期未就绪。',
            actionZh: '请返回首页下拉刷新，或重启应用。',
          ),
        );
      } else if (!serviceConnected) {
        hints.add(
          DiagnosticHint(
            severity: DiagnosticSeverity.error,
            titleEn: 'SEService failed to connect',
            titleZh: '系统 SE 服务连接超时或失败',
            detailEn: se['connectedError']?.toString() ?? 'com.android.se binding did not settle.',
            detailZh: '手机 ROM 可能缺少或禁用了系统安全元件守护进程 (com.android.se)。',
            actionZh: '常见于精简版/原生定制 ROM，可尝试安装 KernelSU/Magisk 的 OTBridge 模块补齐接口。',
          ),
        );
      }
    }

    // 5. Feature OMAPI UICC flag missing
    if (isAndroid && featureOmapiUicc == false) {
      hints.add(
        DiagnosticHint(
          severity: DiagnosticSeverity.warning,
          titleEn: 'ROM lacks android.hardware.se.omapi.uicc feature',
          titleZh: '系统 ROM 未声明 OMAPI UICC 硬件支持',
          detailEn: 'The device manufacturer did not declare OMAPI SIM slot support in system permissions.',
          detailZh: '设备厂商未在系统级声明卡槽 OMAPI 特性，部分定制 ROM 可能彻底屏蔽了应用访问 SIM 卡。',
          actionZh: '如果已 Root，可尝试安装 OTBridge 模块并开启对应服务。',
        ),
      );
    }

    // 6. SE connected, but readers count is zero
    if (serviceConnected && rawReaders.isEmpty && poison == null) {
      hints.add(
        DiagnosticHint(
          severity: DiagnosticSeverity.error,
          titleEn: 'SEService connected, but 0 readers returned by Android',
          titleZh: '系统 OMAPI 服务已连接，但底层返回 0 个读卡器',
          detailEn: 'The Android SE HAL returned an empty reader list for this handset.',
          detailZh: '底层 HAL 未将物理 SIM 卡槽暴露给系统 OMAPI，导致应用获取不到 SIM1/SIM2。',
          actionZh: '这是典型的系统 ROM 屏蔽问题。需配合 Root + OTBridge，或使用蓝牙/USB 读卡器。',
        ),
      );
    }

    // 7. SE connected, readers exist, but NONE match SIM*
    if (serviceConnected && rawReaders.isNotEmpty) {
      final names = rawReaders.map((r) => (r is Map ? r['name']?.toString() : null) ?? '').where((n) => n.isNotEmpty).toList();
      final hasSimReader = rawReaders.any((r) => r is Map && r['acceptedBySimFilter'] == true);
      if (!hasSimReader) {
        hints.add(
          DiagnosticHint(
            severity: DiagnosticSeverity.warning,
            titleEn: 'SE readers detected, but none are SIM card slots',
            titleZh: '检测到底层安全元件，但无 SIM 卡槽读卡器',
            detailEn: 'Android exposed readers: $names (none begin with "SIM"). Only SIM readers mount eUICC profiles.',
            detailZh: '系统暴露的读卡器为: $names（缺少 SIM1/SIM2，仅有 eSE 内置安全芯片等）。',
            actionZh: '说明当前卡槽未接入 OMAPI 总线。若为实体转接卡，建议使用外置读卡器。',
          ),
        );
      } else {
        // 8. SIM reader exists, but reports secureElementPresent == false
        for (final r in rawReaders) {
          if (r is Map && r['acceptedBySimFilter'] == true && r['secureElementPresent'] == false) {
            final name = r['name'] ?? 'SIM';
            hints.add(
              DiagnosticHint(
                severity: DiagnosticSeverity.warning,
                titleEn: 'Reader $name reports no card present',
                titleZh: '读卡器 $name 报告未检测到芯片',
                detailEn: 'isSecureElementPresent returned false.',
                detailZh: '卡槽 $name 中未感应到安全元件。可能未插卡、接触不良、卡片未通电或芯片已休眠。',
                actionZh: '请检查卡片是否插紧、方向是否正确，或在系统设置中重新开关飞行模式。',
              ),
            );
          }
        }
      }
    }

    // 9. Telephony simState check
    final simState = telephony['simState']?.toString();
    if (simState == 'ABSENT') {
      hints.add(
        DiagnosticHint(
          severity: DiagnosticSeverity.info,
          titleEn: 'TelephonyManager reports SIM ABSENT',
          titleZh: '系统基带报告卡槽无 SIM 卡 (ABSENT)',
          detailEn: 'No SIM card detected by the radio stack.',
          detailZh: '基带尚未识别到插入的物理 SIM 卡。',
          actionZh: '请确认卡槽是否装紧，或尝试在系统设置中重新启用对应 SIM 卡。',
        ),
      );
    }

    // 10. Fallback: all sources returned 0
    final total = discovery?.totalReaders ?? 0;
    if (total == 0 && hints.isEmpty) {
      hints.add(
        DiagnosticHint(
          severity: DiagnosticSeverity.warning,
          titleEn: 'No readers found across all enabled sources',
          titleZh: '所有已启用的读卡器渠道均未发现设备',
          detailEn: 'Queried OMAPI, CCID, BLE, and bridge adapters.',
          detailZh: '应用已轮询内置卡槽、USB CCID、蓝牙与远程桥接，未找到任何读卡器。',
          actionZh: '请下拉页面重新扫描，或检查「设置」->「读卡器类型」中对应开关是否开启。',
        ),
      );
    }

    return hints;
  }

  /// Builds a formatted plaintext diagnostic report string.
  static String formatReport({
    required DateTime at,
    required ReaderDiscoveryReport? discovery,
    required Map<String, dynamic> native,
    required AppSettings settings,
    required List<DiagnosticHint> hints,
    required List<LogRecord> logs,
  }) {
    final buf = StringBuffer();

    buf.writeln('================================================================');
    buf.writeln('eSIM-Matrix Diagnostic Report / 诊断与排查报告');
    buf.writeln('Timestamp: ${at.toIso8601String()}');
    buf.writeln('Notice: Sensitive numbers (ICCID/EID/tokens) are masked for privacy.');
    buf.writeln('================================================================');
    buf.writeln();

    // 1. App Info
    buf.writeln('--- 1. Application Info / 应用信息 ---');
    buf.writeln('Version: $kAppVersion (Build $kAppBuildNumber)');
    buf.writeln('Commit: $kCommitHash');
    buf.writeln('Package: ${settings.packageName}');
    buf.writeln('Variant: ${settings.variant} (Privileged=$kIsPrivileged, Esim9=${settings.isEsim9Build})');
    buf.writeln('Platform: ${PlatformX.operatingSystem}');
    buf.writeln();

    // 2. Diagnosis Hints
    buf.writeln('--- 2. Diagnosis Hints / 排查建议 ---');
    if (hints.isEmpty) {
      buf.writeln('✅ No obvious configuration or hardware errors detected.');
    } else {
      for (final h in hints) {
        buf.writeln(h.toPlainString());
      }
    }
    buf.writeln();

    // 3. Reader Discovery Breakdown
    buf.writeln('--- 3. Reader Discovery Breakdown / 读卡器扫描明细 ---');
    if (discovery == null) {
      buf.writeln('No discovery report available yet.');
    } else {
      buf.writeln('Total readers found: ${discovery.totalReaders} (Forced=${discovery.forced})');
      if (discovery.failure != null) {
        buf.writeln('Fatal Scan Failure: ${discovery.failure}');
      }
      for (final s in discovery.sources) {
        final statusTag = switch (s.status) {
          DiscoveryStatus.ok => '[OK]',
          DiscoveryStatus.skipped => '[SKIP]',
          DiscoveryStatus.error => '[ERR]',
        };
        final ms = s.elapsed.inMilliseconds;
        buf.writeln('$statusTag ${s.source.padRight(24)}: ${s.count} reader(s) (${ms}ms)');
        if (s.detail != null && s.detail!.isNotEmpty) {
          buf.writeln('       Detail: ${s.detail}');
        }
        if (s.readerNames.isNotEmpty) {
          buf.writeln('       Readers: ${s.readerNames.join(', ')}');
        }
      }
    }
    buf.writeln();

    // 4. Connector Settings
    buf.writeln('--- 4. Connector Settings / 读卡器配置开关 ---');
    buf.writeln('Built-in OMAPI: ${settings.enableOmapiConnector}');
    buf.writeln('Built-in TMAPI: ${settings.enableTmapiConnector}');
    buf.writeln('Bluetooth LE:   ${settings.enableBleConnector}');
    buf.writeln('USB CCID:       ${settings.enableCcidConnector}');
    buf.writeln('Remote Card:    ${settings.enableRemoteConnector} (autoLoad=${settings.autoLoadRemoteDevices}, urls=${settings.remoCardUrls.length})');
    buf.writeln('NBridge/Root:   providerAvailable=${settings.nbridgeProviderAvailable}, rootDetected=${settings.rootDetected}');
    buf.writeln();

    // 5. Device & ROM Info (Android)
    final device = (native['device'] is Map)
        ? Map<String, dynamic>.from(native['device'] as Map)
        : const <String, dynamic>{};
    if (device.isNotEmpty) {
      buf.writeln('--- 5. Device & ROM Details / 设备与系统 ---');
      buf.writeln('Manufacturer/Model: ${device['manufacturer']} ${device['brand']} ${device['model']} (${device['device']})');
      buf.writeln('Android OS:         ${device['release']} (SDK ${device['sdkInt']}), SecurityPatch: ${device['securityPatch']}');
      buf.writeln('Display/Build:      ${device['romDisplay']}');
      if (device['miuiVersion'] != null) buf.writeln('MIUI Version:       ${device['miuiVersion']}');
      if (device['hyperOsVersion'] != null) buf.writeln('HyperOS Version:    ${device['hyperOsVersion']}');
      buf.writeln('OMAPI Features:     UICC=${device['featureOmapiUicc']}, eSE=${device['featureOmapiEse']}, SD=${device['featureOmapiSd']}');
      buf.writeln('Telephony eUICC:    ${device['featureTelephonyEuicc']}');
      buf.writeln('READ_PHONE_STATE:   ${device['readPhoneStateGranted']}');
      buf.writeln();
    }

    // 6. Telephony & SIM Slot Info
    final telephony = (native['telephony'] is Map)
        ? Map<String, dynamic>.from(native['telephony'] as Map)
        : const <String, dynamic>{};
    if (telephony.isNotEmpty) {
      buf.writeln('--- 6. Telephony & SIM Slots / 基带与卡槽状态 ---');
      buf.writeln('Active Modems: ${telephony['modemCount']}, Main SIM State: ${telephony['simState']}');
      final slotStates = telephony['slotSimStates'];
      if (slotStates is List) {
        buf.writeln('Slot States:   ${slotStates.join(', ')}');
      }
      final subs = telephony['activeSubscriptions'];
      if (subs is List && subs.isNotEmpty) {
        buf.writeln('Subscriptions:');
        for (final sub in subs) {
          buf.writeln('  - $sub');
        }
      } else if (subs != null) {
        buf.writeln('Subscriptions: $subs');
      }
      buf.writeln();
    }

    // 7. Native OMAPI / SEService State
    final se = (native['se'] is Map)
        ? Map<String, dynamic>.from(native['se'] as Map)
        : const <String, dynamic>{};
    if (se.isNotEmpty) {
      buf.writeln('--- 7. Native OMAPI / SEService State / 系统安全元件服务 ---');
      buf.writeln('Service Created:    ${se['serviceCreated']}');
      buf.writeln('Service Connected:  ${se['serviceConnected']}');
      buf.writeln('Lifecycle OK:       ${se['lifecycleAccepting']}');
      buf.writeln('Poison State:       ${se['poison'] ?? 'None (Healthy)'}');
      if (se['connectedError'] != null) {
        buf.writeln('Connection Error:   ${se['connectedError']}');
      }
      final rawReaders = se['readers'];
      if (rawReaders is List) {
        buf.writeln('Raw SE Readers (${rawReaders.length}):');
        for (final r in rawReaders) {
          if (r is Map) {
            buf.writeln(
              '  - ${r['name']}: present=${r['secureElementPresent']}, '
              'acceptedBySimFilter=${r['acceptedBySimFilter']}, '
              'localSession=${r['localSession']}, channels=${r['openChannels']}',
            );
          } else {
            buf.writeln('  - $r');
          }
        }
      }
      final cached = se['cachedStatus'];
      if (cached is Map && cached.isNotEmpty) {
        buf.writeln('Cached Status:      $cached');
      }
      buf.writeln();
    }

    // 8. Recent Logs (Filtered and Redacted)
    buf.writeln('--- 8. Recent Filtered Logs / 近期关键日志 (已脱敏) ---');
    if (logs.isEmpty) {
      buf.writeln('No logs in memory.');
    } else {
      for (final l in logs) {
        final stamp = l.time.toIso8601String().substring(11, 23);
        final line = '[$stamp] ${l.level.name.padRight(7)} [${l.loggerName}]: ${l.message}';
        buf.writeln(redact(line));
      }
    }
    buf.writeln('================================================================');

    // Final pass over every section, not just the log tail: reader ids,
    // telephony strings and exception messages carry the same material.
    return redact(buf.toString());
  }

  /// Collects a live diagnostic report snapshot asynchronously.
  static Future<DiagnosticsSnapshot> collect({
    CompositeAdapter? adapter,
    int maxLogLines = 80,
  }) async {
    final compAdapter = adapter ?? CompositeAdapter();
    final at = DateTime.now();

    // 1. Fetch native diagnostics if on Android
    Map<String, dynamic> native = const {};
    if (PlatformX.isAndroid) {
      try {
        native = await OmapiAdapter.fetchDiagnostics();
      } catch (e) {
        native = <String, dynamic>{'error': 'fetchDiagnostics failed: $e'};
      }
    }

    // 2. Fetch last discovery report (or run if absent)
    var discovery = compAdapter.lastDiscoveryReport;
    if (discovery == null) {
      try {
        await compAdapter.listReaders(force: false);
        discovery = compAdapter.lastDiscoveryReport;
      } catch (_) {
        discovery = compAdapter.lastDiscoveryReport;
      }
    }

    // 3. Derive actionable hints
    final settings = AppSettings();
    final hints = deriveHints(
      discovery: discovery,
      native: native,
      settings: settings,
    );

    // 4. Filter recent logs: prioritize warnings/errors or relevant loggers
    final allLogs = LogBuffer().logs;
    final relevantLogs = allLogs.where((l) {
      if (l.level >= Level.WARNING) return true;
      final name = l.loggerName.toLowerCase();
      return name.contains('omapi') ||
          name.contains('composite') ||
          name.contains('nbridge') ||
          name.contains('reader') ||
          name.contains('telephony') ||
          name.contains('ble');
    }).toList();

    final tailLogs = relevantLogs.length > maxLogLines
        ? relevantLogs.sublist(relevantLogs.length - maxLogLines)
        : relevantLogs;

    // 5. Format plaintext report
    final reportText = formatReport(
      at: at,
      discovery: discovery,
      native: native,
      settings: settings,
      hints: hints,
      logs: tailLogs,
    );

    final se = (native['se'] is Map)
        ? Map<String, dynamic>.from(native['se'] as Map)
        : const <String, dynamic>{};

    return DiagnosticsSnapshot(
      at: at,
      hints: hints,
      reportText: reportText,
      totalReaders: discovery?.totalReaders ?? 0,
      omapiConnected: se['serviceConnected'] == true,
      omapiPoisoned: se['poison'] != null,
    );
  }
}
