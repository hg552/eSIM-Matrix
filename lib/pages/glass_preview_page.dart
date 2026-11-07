import 'package:flutter/material.dart';

import '../settings/app_settings.dart';
import '../widgets/glass/glass_surface.dart';

/// A place to judge the experimental glass material without re-skinning a
/// real screen first: one card, one segmented control, one dock and a sheet,
/// drawn with whatever intensity the settings currently hold.
class GlassPreviewPage extends StatelessWidget {
  const GlassPreviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings(),
      builder: (context, _) {
        final settings = AppSettings();
        return Scaffold(
          backgroundColor: const Color(0xFF07080F),
          body: Stack(
            fit: StackFit.expand,
            children: [
              const GlassPreviewBackdrop(),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.arrow_back),
                          ),
                          const Spacer(),
                          Text(
                            settings.enableGlassUi
                                ? '玻璃：${_label(settings.glassIntensity)}'
                                : '玻璃：已关闭',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '液态玻璃预览',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.62),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '3D 环境已就绪',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: 18),
                      const _PreviewSegmented(),
                      const SizedBox(height: 16),
                      const _PreviewCard(),
                      const SizedBox(height: 12),
                      const _PreviewIdleCard(
                        flag: '🇺🇸',
                        name: 'Saily',
                        region: 'US · T-Mobile',
                        iccid: '8901 2402 ···· 3317',
                        trailing: '-92 dBm',
                      ),
                      const Spacer(),
                      GlassSurface(
                        radius: 30,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        child: Row(
                          children: const [
                            _DockItem(Icons.sim_card_outlined, '卡片', true),
                            _DockItem(Icons.cell_tower_outlined, '网络', false),
                            _DockItem(Icons.forum_outlined, '短信', false),
                            _DockItem(Icons.tune_outlined, '设置', false),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Center(
                        child: Text(
                          settings.enableGlassUi
                              ? '强度 ${_label(settings.glassIntensity)} · '
                                  '滚动降级 '
                                  '${settings.glassDegradeOnScroll ? "开" : "关"}'
                              : '打开「液态玻璃界面」后此页才会渲染模糊',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.45),
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            backgroundColor: Colors.white.withValues(alpha: 0.14),
            foregroundColor: Colors.white,
            onPressed: () => _showSheet(context),
            label: const Text('打开面板'),
            icon: const Icon(Icons.layers_outlined),
          ),
        );
      },
    );
  }

  static String _label(String intensity) => switch (intensity) {
    'soft' => '轻柔',
    'strong' => '厚重',
    _ => '标准',
  };

  void _showSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: GlassSurface(
            radius: 36,
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                  ),
                ),
                const Text(
                  '指定虚拟定位',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'ICCID 8901 5200 0146 3221 7637',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 11.5,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 14),
                const _SheetRow(
                  flag: '🇭🇰',
                  title: '中国香港 · 尖沙咀海旁',
                  subtitle: '22.3193, 114.1694',
                  selected: true,
                ),
                const _SheetRow(
                  flag: '🇺🇸',
                  title: '美国 · 洛杉矶市政中心',
                  subtitle: '34.0522, -118.2437',
                  selected: false,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('确定绑定'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class GlassPreviewBackdrop extends StatelessWidget {
  const GlassPreviewBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF1B2A6B),
                Color(0xFF3B1E6E),
                Color(0xFF6B1F5A),
                Color(0xFF8A3B2A),
              ],
              stops: [0, 0.35, 0.7, 1],
            ),
          ),
        ),
        _blob(Alignment.topLeft, 620, const Color(0xFF4C7CFF)),
        _blob(Alignment(1.1, -0.5), 520, const Color(0xFFC05CFF)),
        _blob(Alignment(0.9, 0.9), 560, const Color(0xFF00E0B0), 0.5),
        _blob(Alignment(-0.95, 0.55), 520, const Color(0xFFFF7A4D), 0.5),
      ],
    );
  }

  Widget _blob(Alignment align, double size, Color color, [double alpha = 0.85]) {
    return Align(
      alignment: align,
      child: IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withValues(alpha: alpha),
                color.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewSegmented extends StatelessWidget {
  const _PreviewSegmented();

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      radius: 22,
      padding: const EdgeInsets.all(4),
      child: Row(
        children: const [
          _Segment('卡片', true),
          _Segment('网络', false),
          _Segment('短信', false),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment(this.label, this.selected);

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: selected ? Colors.white.withValues(alpha: 0.22) : null,
          border: selected
              ? Border.all(color: Colors.white.withValues(alpha: 0.28))
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: Colors.white.withValues(alpha: selected ? 0.98 : 0.62),
          ),
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard();

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      radius: 30,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _FlagBadge('🇭🇰'),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'ClubSim',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'HK · CSL 454-19',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: const Color(0xFF4BE3A3).withValues(alpha: 0.16),
                  border: Border.all(
                    color: const Color(0xFF4BE3A3).withValues(alpha: 0.38),
                  ),
                ),
                child: const Text(
                  '已激活',
                  style: TextStyle(
                    color: Color(0xFF4BE3A3),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '8901 5200 0146 3221 7637',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),
              fontSize: 12.5,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: const [
              _Stat('信号', '-85', 'dBm'),
              _StatDivider(),
              _Stat('出口', 'HK', 'AS4760'),
              _StatDivider(),
              _Stat('定位', '22.3193', '114.1694'),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewIdleCard extends StatelessWidget {
  const _PreviewIdleCard({
    required this.flag,
    required this.name,
    required this.region,
    required this.iccid,
    required this.trailing,
  });

  final String flag;
  final String name;
  final String region;
  final String iccid;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          _FlagBadge(flag),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '$region · $iccid',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          Text(
            trailing,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _FlagBadge extends StatelessWidget {
  const _FlagBadge(this.flag);

  final String flag;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.26),
            Colors.white.withValues(alpha: 0.08),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
      ),
      child: Text(flag, style: const TextStyle(fontSize: 22)),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.unit);

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  unit,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 10.5,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 26,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: Colors.white.withValues(alpha: 0.12),
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.flag,
    required this.title,
    required this.subtitle,
    required this.selected,
  });

  final String flag;
  final String title;
  final String subtitle;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white.withValues(alpha: selected ? 0.16 : 0.06),
        border: Border.all(
          color: Colors.white.withValues(alpha: selected ? 0.32 : 0.12),
        ),
      ),
      child: Row(
        children: [
          Text(flag, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem(this.icon, this.label, this.active);

  final IconData icon;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 21,
            color: Colors.white.withValues(alpha: active ? 0.98 : 0.5),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: active ? 0.95 : 0.45),
              fontSize: 10.5,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
