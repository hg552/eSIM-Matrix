import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'profiles_screen.dart';
import 'network_status_page.dart';
import 'sms_relay_page.dart';
import 'location_console_page.dart';
import 'proxy_console_page.dart';
import 'buy_page.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../settings/app_settings.dart';
import '../plugins/plugin_manager.dart';
import 'package:flutter/foundation.dart';
import '../utils/platform_adapter.dart';
import '../services/sms_relay_service.dart';
import '../services/remote_gateway_service.dart';
import '../widgets/lazy_tab_body.dart';
import '../widgets/glass/glass_surface.dart';

class MainTabScreen extends StatefulWidget {
  const MainTabScreen({super.key});

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  bool _isHoveringTopBar = false;
  bool _smsRelayAvailable = PlatformX.isAndroid;
  bool _permissionsRequested = false;

  // Base pages that are always there or standard
  // We'll construct the active list in build or compute it.

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppSettings().addListener(_onSettingsChanged);
    if (PlatformX.isAndroid) unawaited(_loadSmsRelayAvailability());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppSettings().removeListener(_onSettingsChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && PlatformX.isAndroid) {
      if (!_smsRelayAvailable) {
        setState(() => _smsRelayAvailable = true);
      }
      if (!_permissionsRequested) {
        unawaited(_requestAndroidPermissions());
      }
    }
  }

  void _onSettingsChanged() {
    setState(() {});
  }

  Future<void> _requestAndroidPermissions() async {
    try {
      await [
        Permission.phone,
        Permission.sms,
        Permission.notification,
      ].request();
      _permissionsRequested = true;
    } catch (_) {
      // Activity may not be attached yet during background pre-warm; retry on resume.
    }
  }

  Future<void> _loadSmsRelayAvailability() async {
    var available = PlatformX.isAndroid;
    try {
      available = await const SmsRelayService().isAvailable() || PlatformX.isAndroid;
    } catch (_) {
      available = PlatformX.isAndroid;
    }
    if (mounted && available != _smsRelayAvailable) {
      setState(() => _smsRelayAvailable = available);
    }
    if (available) {
      unawaited(RemoteGatewayService.instance.resumeIfEnabled());
      await _requestAndroidPermissions();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final settings = AppSettings();
    final glass = settings.enableGlassUi;

    final pluginTabs = PluginManager().appTabs;
    final tabEntries = <_MainTabEntry>[
      _MainTabEntry(
        id: 'profiles',
        label: l10n.manage,
        icon: Icons.sim_card_outlined,
        activeIcon: Icons.sim_card,
        pageBuilder: (_) => const ProfilesScreen(),
      ),
      if (PlatformX.isAndroid)
        _MainTabEntry(
          id: 'network-status',
          label: l10n.networkStatusTab,
          icon: Icons.network_cell,
          activeIcon: Icons.network_cell,
          pageBuilder: (_) => NetworkStatusPage(
            controller: RemoteGatewayService.instance.profiles,
          ),
        ),
      if (PlatformX.isAndroid)
        _MainTabEntry(
          id: 'location-console',
          label: l10n.locationConsoleTab,
          icon: Icons.my_location_outlined,
          activeIcon: Icons.my_location,
          pageBuilder: (_) => const LocationConsolePage(),
        ),
      _MainTabEntry(
        id: 'proxy-console',
        label: l10n.proxyConsoleTab,
        icon: Icons.wifi_tethering_outlined,
        activeIcon: Icons.wifi_tethering,
        pageBuilder: (_) => const ProxyConsolePage(),
      ),
      if (_smsRelayAvailable)
        _MainTabEntry(
          id: 'sms-relay',
          label: l10n.smsRelayTab,
          icon: Icons.sms_outlined,
          activeIcon: Icons.sms,
          pageBuilder: (_) => const SmsRelayPage(),
        ),
      ...pluginTabs.map(
        (tab) => _MainTabEntry(
          id: 'plugin:${tab.id}',
          label: tab.label,
          icon: tab.icon,
          activeIcon: tab.activeIcon,
          pageBuilder: tab.builder,
        ),
      ),
    ];

    // Variant Tabs from Config
    if (settings.enableBrowser) {
      for (final tabConfig in settings.variantTabs) {
        if (!tabConfig.isEnabled) continue;
        if (!settings.isOnline) continue;
        if (kIsWeb) continue;
        if (PlatformX.isWindows || PlatformX.isLinux) continue;

        tabEntries.add(
          _MainTabEntry(
            id: 'browser:${tabConfig.url}',
            label: tabConfig.label,
            icon: _resolveIcon(tabConfig.icon, false),
            activeIcon: _resolveIcon(tabConfig.icon, true),
            pageBuilder: (_) =>
                BuyPage(url: tabConfig.url, title: tabConfig.title),
          ),
        );
      }
    }

    if (_currentIndex >= tabEntries.length) _currentIndex = 0;
    final pages = List<Widget>.generate(tabEntries.length, (index) {
      final entry = tabEntries[index];
      return LazyTabBody(
        key: ValueKey(entry.id),
        active: index == _currentIndex,
        builder: entry.pageBuilder,
      );
    }, growable: false);
    final tabs = List<Widget>.generate(
      tabEntries.length,
      (index) => _buildTabItem(
        context,
        index: index,
        isActive: _currentIndex == index,
        icon: tabEntries[index].icon,
        activeIcon: tabEntries[index].activeIcon,
        label: tabEntries[index].label,
      ),
      growable: false,
    );

    final showBottomBar = tabs.length > 1;
    final isDesktop = MediaQuery.of(context).size.width >= 600;

    Widget body = IndexedStack(index: _currentIndex, children: pages);

    // Add floating top bar for desktop
    if (isDesktop && showBottomBar) {
      Widget topBarContent = AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: glass
              ? (theme.brightness == Brightness.dark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.white.withValues(alpha: 0.55))
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.9,
                ),
          borderRadius: BorderRadius.circular(24),
          border: glass
              ? Border.all(
                  color: Colors.white.withValues(alpha: 0.22),
                  width: 1,
                )
              : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(tabs.length, (index) {
            final bool isActive = _currentIndex == index;
            final entry = tabEntries[index];
            final label = entry.label;
            final icon = isActive ? entry.activeIcon : entry.icon;

            return InkWell(
              onTap: () {
                setState(() => _currentIndex = index);
                HapticFeedback.selectionClick();
              },
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 12,
                ),
                decoration: isActive
                    ? BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(20),
                      )
                    : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      icon,
                      size: 18,
                      color: isActive
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      child: _isHoveringTopBar
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(width: 8),
                                Text(
                                  label,
                                  style: TextStyle(
                                    color: isActive
                                        ? theme.colorScheme.onPrimary
                                        : theme
                                              .colorScheme
                                              .onSurfaceVariant,
                                    fontWeight: isActive
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    fontSize: 13,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      );

      final topBar = glass
          ? GlassSurface(
              radius: 24,
              child: topBarContent,
            )
          : topBarContent;

      body = Stack(
        children: [
          body,
          Positioned(
            top: 4,
            left: 0,
            right: 0,
            child: Center(
              child: MouseRegion(
                onEnter: (_) => setState(() => _isHoveringTopBar = true),
                onExit: (_) => setState(() => _isHoveringTopBar = false),
                child: topBar,
              ),
            ),
          ),
        ],
      );
    }

    Widget? bottomNav;
    if (showBottomBar && !isDesktop) {
      final bottomBarContent = Container(
        decoration: BoxDecoration(
          color: glass
              ? Colors.transparent
              : theme.colorScheme.surface.withValues(alpha: 0.95),
          border: Border(
            top: BorderSide(
              color: glass
                  ? Colors.white.withValues(alpha: 0.18)
                  : theme.dividerColor.withValues(alpha: 0.1),
              width: 1,
            ),
          ),
        ),
        child: SafeArea(
          child: SizedBox(
            height: 56, // Shorter height
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: tabs,
            ),
          ),
        ),
      );

      bottomNav = glass
          ? GlassSurface(
              borderRadius: BorderRadius.zero,
              child: bottomBarContent,
            )
          : bottomBarContent;
    }

    final scaffold = Scaffold(
      backgroundColor: glass ? Colors.transparent : null,
      body: body,
      bottomNavigationBar: bottomNav,
    );

    if (glass) {
      return Stack(
        children: [
          const Positioned.fill(child: GlassBackdrop()),
          scaffold,
        ],
      );
    }

    return scaffold;
  }

  Widget _buildTabItem(
    BuildContext context, {
    required int index,
    required bool isActive,
    required IconData icon,
    required IconData activeIcon,
    required String label,
  }) {
    final theme = Theme.of(context);
    final color = isActive
        ? theme.colorScheme.primary
        : AppTheme.onSurfaceSubtle(context);

    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _currentIndex = index;
          });
          HapticFeedback.selectionClick();
        },
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(isActive ? activeIcon : icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _resolveIcon(String name, bool active) {
    switch (name) {
      case 'web':
        return active ? Icons.explore : Icons.explore_outlined;
      case 'shopping_cart':
        return active ? Icons.shopping_cart : Icons.shopping_cart_outlined;
      case 'language':
        return active ? Icons.language : Icons.language_outlined;
      case 'sim_card':
        return active ? Icons.sim_card : Icons.sim_card_outlined;
      case 'devices_other':
        return active ? Icons.devices_other : Icons.devices_other_outlined;
      default:
        return active ? Icons.circle : Icons.circle_outlined;
    }
  }
}

class _MainTabEntry {
  const _MainTabEntry({
    required this.id,
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.pageBuilder,
  });

  final String id;
  final String label;
  final IconData icon;
  final IconData activeIcon;
  final WidgetBuilder pageBuilder;
}
