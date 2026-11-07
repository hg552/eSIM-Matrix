import 'dart:ui';

import 'package:flutter/material.dart';

import '../../settings/app_settings.dart';

/// One sheet of the experimental "liquid glass" material.
///
/// The look is built from three layers, in this order: a backdrop filter that
/// blurs *and* saturates whatever is behind the panel, a tinted gradient that
/// gives the pane its body, and a rim/sheen pass that reads as polished glass
/// catching light. Everything is driven by [AppSettings.enableGlassUi], so a
/// caller can drop this widget in unconditionally and the app's normal style
/// comes back as soon as the switch is off.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = 28,
    this.padding = EdgeInsets.zero,
    this.blurOverride,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// Used by lists that scroll: the caller can pass a cheaper sigma while
  /// motion is on screen so the GPU is not asked to re-blur every frame.
  final double? blurOverride;

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings();
    if (!settings.enableGlassUi) {
      return Padding(padding: padding, child: child);
    }

    final profile = GlassProfile.of(settings.glassIntensity);
    final sigma = blurOverride ?? profile.blur;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.compose(
          outer: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          inner: ColorFilter.matrix(<double>[
            profile.saturation, 0, 0, 0, 0, //
            0, profile.saturation, 0, 0, 0, //
            0, 0, profile.saturation, 0, 0, //
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
                Colors.white.withValues(alpha: profile.tint + 0.06),
                Colors.white.withValues(alpha: profile.tint * 0.55),
                Colors.white.withValues(alpha: profile.tint * 0.30),
              ],
              stops: const [0, 0.55, 1],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: profile.rim),
              width: 1,
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment(0.35, 0.75),
                        colors: [
                          Colors.white.withValues(alpha: profile.sheen),
                          Colors.white.withValues(alpha: 0.015),
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

/// The three intensities the switch offers, so the numbers live in one place
/// instead of being sprinkled through pages.
class GlassProfile {
  const GlassProfile({
    required this.blur,
    required this.tint,
    required this.saturation,
    required this.rim,
    required this.sheen,
  });

  final double blur;
  final double tint;
  final double saturation;
  final double rim;
  final double sheen;

  /// A cheap sigma for lists that are actively scrolling.
  double get scrollingBlur => blur <= 18 ? 8 : blur * 0.45;

  static const soft = GlassProfile(
    blur: 18,
    tint: 0.07,
    saturation: 1.15,
    rim: 0.18,
    sheen: 0.10,
  );

  static const normal = GlassProfile(
    blur: 28,
    tint: 0.13,
    saturation: 1.22,
    rim: 0.26,
    sheen: 0.16,
  );

  static const strong = GlassProfile(
    blur: 40,
    tint: 0.18,
    saturation: 1.30,
    rim: 0.30,
    sheen: 0.20,
  );

  static GlassProfile of(String intensity) => switch (intensity) {
    'soft' => soft,
    'strong' => strong,
    _ => normal,
  };
}

/// The colourful field the glass is meant to sit on.
///
/// A backdrop blur over a flat dark background is invisible: there is nothing
/// to blur. This paints the soft colour blobs the material was designed
/// against, so turning the switch on actually changes what the eye sees.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key});

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
                Color(0xFF121A3A),
                Color(0xFF241344),
                Color(0xFF3A1233),
                Color(0xFF2A1410),
              ],
              stops: [0, 0.35, 0.7, 1],
            ),
          ),
        ),
        _blob(Alignment.topLeft, 640, const Color(0xFF4C7CFF), 0.55),
        _blob(const Alignment(1.1, -0.5), 540, const Color(0xFFC05CFF), 0.45),
        _blob(const Alignment(0.9, 0.95), 580, const Color(0xFF00E0B0), 0.28),
        _blob(const Alignment(-0.95, 0.55), 540, const Color(0xFFFF7A4D), 0.26),
      ],
    );
  }

  Widget _blob(Alignment align, double size, Color color, double alpha) {
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
