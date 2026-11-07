import 'dart:ui';

import 'package:flutter/material.dart';

void main() {
  runApp(const GlassConceptApp());
}

class GlassConceptApp extends StatelessWidget {
  const GlassConceptApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF07080F),
        fontFamily: 'Roboto',
      ),
      home: const GlassHome(),
    );
  }
}

// ---------------------------------------------------------------- wallpaper

class AuroraBackdrop extends StatelessWidget {
  const AuroraBackdrop({super.key});

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
        const _Blob(
          alignment: Alignment(-1.0, -1.0),
          size: 620,
          color: Color(0xFF4C7CFF),
          opacity: 0.95,
        ),
        const _Blob(
          alignment: Alignment(1.1, -0.5),
          size: 520,
          color: Color(0xFFC05CFF),
          opacity: 0.85,
        ),
        const _Blob(
          alignment: Alignment(0.9, 0.9),
          size: 560,
          color: Color(0xFF00E0B0),
          opacity: 0.55,
        ),
        const _Blob(
          alignment: Alignment(-0.95, 0.55),
          size: 520,
          color: Color(0xFFFF7A4D),
          opacity: 0.55,
        ),
        // A soft light falling across the top-left, the highlight the glass
        // edges will pick up.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment(0.4, 0.6),
              colors: [Color(0x55FFFFFF), Color(0x00FFFFFF)],
            ),
          ),
        ),
      ],
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({
    required this.alignment,
    required this.size,
    required this.color,
    required this.opacity,
  });

  final Alignment alignment;
  final double size;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                color.withValues(alpha: opacity),
                color.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- glass

/// A frosted panel that reads like a sheet of glass: heavy backdrop blur with
/// a saturation lift, a diagonal specular sheen, and a hairline rim that is
/// brighter where light would hit it.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = 28,
    this.blur = 28,
    this.tintAlpha = 0.13,
    this.sheen = true,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final double blur;
  final double tintAlpha;
  final bool sheen;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.compose(
          outer: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          inner: const ColorFilter.matrix(<double>[
            1.22, 0, 0, 0, 0, //
            0, 1.22, 0, 0, 0, //
            0, 0, 1.22, 0, 0, //
            0, 0, 0, 1, 0,
          ]),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: tintAlpha + 0.07),
                Colors.white.withValues(alpha: tintAlpha * 0.55),
                Colors.white.withValues(alpha: tintAlpha * 0.28),
              ],
              stops: const [0, 0.55, 1],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.26),
              width: 1,
            ),
          ),
          child: Stack(
            children: [
              if (sheen)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(radius),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment(0.35, 0.75),
                          colors: [
                            Colors.white.withValues(alpha: 0.16),
                            Colors.white.withValues(alpha: 0.02),
                            Colors.transparent,
                          ],
                          stops: const [0, 0.35, 0.7],
                        ),
                      ),
                    ),
                  ),
                ),
              Padding(padding: padding, child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// The thin bright arc that sells "polished glass" on rounded corners.
class GlassRim extends StatelessWidget {
  const GlassRim({super.key, this.radius = 28, this.opacity = 0.55});

  final double radius;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: opacity * 0.35),
              Colors.transparent,
              Colors.white.withValues(alpha: opacity * 0.12),
            ],
            stops: const [0, 0.4, 1],
          ),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------- home

class GlassHome extends StatelessWidget {
  const GlassHome({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const AuroraBackdrop(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _StatusBar(),
                  const SizedBox(height: 10),
                  const _Header(),
                  const SizedBox(height: 18),
                  const _Segmented(),
                  const SizedBox(height: 16),
                  const _ActiveCard(),
                  const SizedBox(height: 12),
                  const _IdleCard(
                    flag: '🇺🇸',
                    name: 'Saily',
                    region: 'US · T-Mobile',
                    iccid: '8901 2402 ···· 3317',
                    trailing: '-92 dBm',
                  ),
                  const SizedBox(height: 12),
                  const _IdleCard(
                    flag: '🇪🇪',
                    name: 'Elisa',
                    region: 'EE · Telia',
                    iccid: '8944 5012 ···· 8820',
                    trailing: '保号 12d',
                  ),
                  const Spacer(),
                  const _Dock(),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          if (Uri.base.queryParameters['sheet'] == '1') const _LocationSheet(),
        ],
      ),
    );
  }
}

class _LocationSheet extends StatelessWidget {
  const _LocationSheet();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Dimming is part of the glass story: the content behind must stay
        // legible through the sheet, not be erased by a flat scrim.
        Container(color: Colors.black.withValues(alpha: 0.28)),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: GlassPanel(
              radius: 36,
              blur: 40,
              tintAlpha: 0.18,
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
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      color: Colors.white.withValues(alpha: 0.10),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.16),
                      ),
                    ),
                    child: Row(
                      children: const [
                        _SheetSeg(label: '常用模板', selected: true),
                        _SheetSeg(label: '手动经纬度', selected: false),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
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
                  const _SheetRow(
                    flag: '🇯🇵',
                    title: '日本 · 东京新宿商业区',
                    subtitle: '35.6938, 139.7034',
                    selected: false,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            color: Colors.white.withValues(alpha: 0.10),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.18),
                            ),
                          ),
                          child: Text(
                            '取消',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.75),
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: Container(
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xFF7FA8FF), Color(0xFF4C6FEA)],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF4C6FEA)
                                    .withValues(alpha: 0.45),
                                blurRadius: 22,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Text(
                            '确定绑定',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SheetSeg extends StatelessWidget {
  const _SheetSeg({required this.label, required this.selected});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: selected ? Colors.white.withValues(alpha: 0.26) : null,
          border: selected
              ? Border.all(color: Colors.white.withValues(alpha: 0.30))
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: Colors.white.withValues(alpha: selected ? 0.98 : 0.6),
          ),
        ),
      ),
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
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: selected ? 0.9 : 0.35),
                width: 1.5,
              ),
              color: selected ? Colors.white.withValues(alpha: 0.9) : null,
            ),
            child: selected
                ? const Icon(Icons.check, size: 13, color: Color(0xFF2A3A8F))
                : null,
          ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: Colors.white,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
    );
    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 6, top: 4),
      child: Row(
        children: [
          const Text('11:57', style: style),
          const Spacer(),
          Text(
            '5G  ▮▮▮  87%',
            style: style.copyWith(color: Colors.white.withValues(alpha: 0.88)),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'eSIM-Matrix',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.62),
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.6,
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
          ],
        ),
        const Spacer(),
        _CircleButton(icon: Icons.refresh_rounded),
      ],
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.22),
                Colors.white.withValues(alpha: 0.06),
              ],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
          ),
          child: Icon(icon, size: 20, color: Colors.white.withValues(alpha: 0.92)),
        ),
      ),
    );
  }
}


class _Segmented extends StatelessWidget {
  const _Segmented();

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.all(4),
      radius: 22,
      blur: 22,
      tintAlpha: 0.09,
      sheen: false,
      child: Row(
        children: [
          _Segment(label: '卡片', selected: true),
          _Segment(label: '网络', selected: false),
          _Segment(label: '短信', selected: false),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({required this.label, required this.selected});

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
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: 0.30),
                    Colors.white.withValues(alpha: 0.12),
                  ],
                )
              : null,
          border: selected
              ? Border.all(color: Colors.white.withValues(alpha: 0.28))
              : null,
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
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

class _ActiveCard extends StatelessWidget {
  const _ActiveCard();

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      radius: 30,
      blur: 32,
      tintAlpha: 0.16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _FlagBadge(flag: '🇭🇰'),
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
              _Pill(text: '已激活', tone: _PillTone.good),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '8901 5200 0146 3221 7637',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),
              fontSize: 12.5,
              letterSpacing: 1.1,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: const [
              _Stat(label: '信号', value: '-85', unit: 'dBm'),
              _StatDivider(),
              _Stat(label: '出口', value: 'HK', unit: 'AS4760'),
              _StatDivider(),
              _Stat(label: '定位', value: '22.3193', unit: '114.1694'),
            ],
          ),
        ],
      ),
    );
  }
}

class _FlagBadge extends StatelessWidget {
  const _FlagBadge({required this.flag});

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
  const _Stat({required this.label, required this.value, required this.unit});

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
                  letterSpacing: -0.2,
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

enum _PillTone { good, warn }

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.tone});

  final String text;
  final _PillTone tone;

  @override
  Widget build(BuildContext context) {
    final color = tone == _PillTone.good
        ? const Color(0xFF4BE3A3)
        : const Color(0xFFFFC16A);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.16),
        border: Border.all(color: color.withValues(alpha: 0.38)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _IdleCard extends StatelessWidget {
  const _IdleCard({
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
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      radius: 24,
      blur: 24,
      tintAlpha: 0.09,
      child: Row(
        children: [
          _FlagBadge(flag: flag),
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
                    letterSpacing: 0.3,
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

class _Dock extends StatelessWidget {
  const _Dock();

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      radius: 30,
      blur: 34,
      tintAlpha: 0.14,
      child: Row(
        children: const [
          _DockItem(icon: Icons.sim_card_outlined, label: '卡片', active: true),
          _DockItem(icon: Icons.cell_tower_outlined, label: '网络', active: false),
          _DockItem(icon: Icons.forum_outlined, label: '短信', active: false),
          _DockItem(icon: Icons.tune_outlined, label: '设置', active: false),
        ],
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.icon,
    required this.label,
    required this.active,
  });

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
