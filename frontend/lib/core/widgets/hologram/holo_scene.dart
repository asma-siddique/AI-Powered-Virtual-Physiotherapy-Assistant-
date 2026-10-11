import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import 'holo_figure.dart';

/// The dark room the app's large holograms stand in: a night gradient, two
/// soft lights and a floor grid running to the horizon.
class HoloNight extends StatelessWidget {
  const HoloNight({super.key, required this.child, this.horizon = 0.7});

  final Widget child;

  /// How far down the floor's horizon sits, 0 (top) to 1 (bottom).
  final double horizon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: AppColors.immersiveGradient),
      child: CustomPaint(
        painter: _NightPainter(horizon),
        child: HoloBackdrop(dark: true, child: child),
      ),
    );
  }
}

class _NightPainter extends CustomPainter {
  const _NightPainter(this.horizon);

  final double horizon;

  @override
  void paint(Canvas canvas, Size size) {
    // Nothing here may spill onto whatever sits beside the scene.
    canvas.clipRect(Offset.zero & size);

    // A teal light from above and a warm one low on the other side.
    void light(Offset centre, double radius, Color color) {
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..shader = ui.Gradient.radial(centre, radius, [
            color,
            color.withValues(alpha: 0),
          ]),
      );
    }

    light(
      Offset(size.width * 0.72, size.height * 0.28),
      size.shortestSide * 0.75,
      AppColors.primaryMint.withValues(alpha: 0.2),
    );
    light(
      Offset(size.width * 0.12, size.height * 0.92),
      size.shortestSide * 0.6,
      AppColors.clay.withValues(alpha: 0.2),
    );

    // The floor: lines running away to one point, and lines across them
    // that crowd together towards the horizon.
    final top = size.height * horizon;
    final vanish = Offset(size.width / 2, top);
    final floor = Rect.fromLTRB(0, top, size.width, size.height);
    final line = Paint()
      ..strokeWidth = 1
      ..shader = ui.Gradient.linear(floor.topCenter, floor.bottomCenter, [
        AppColors.primaryMint.withValues(alpha: 0),
        AppColors.primaryMint.withValues(alpha: 0.22),
      ]);
    canvas.save();
    canvas.clipRect(floor);
    const rays = 22;
    for (var i = -rays; i <= rays; i++) {
      canvas.drawLine(
        vanish,
        Offset(size.width / 2 + i * size.width * 0.11, size.height),
        line,
      );
    }
    for (var i = 1; i <= 12; i++) {
      final y = top + floor.height * math.pow(i / 12, 2.2);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_NightPainter old) => old.horizon != horizon;
}

/// A small pane of dark glass for a reading beside a hologram.
class HoloChip extends StatelessWidget {
  const HoloChip({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryMint.withValues(alpha: 0.12),
            blurRadius: 18,
          ),
        ],
      ),
      child: child,
    );
  }
}

/// A ring that fills to [value] out of 100 around the number.
class HoloGauge extends StatelessWidget {
  const HoloGauge({super.key, required this.value, this.size = 64});

  final int value;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _GaugePainter(value / 100),
        child: Center(
          child: Text(
            '$value',
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.34,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  const _GaugePainter(this.fraction);

  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(4);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..color = Colors.white.withValues(alpha: 0.14);
    canvas.drawArc(rect, 0, math.pi * 2, false, track);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * fraction,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.sweep(
          rect.center,
          const [
            AppColors.primaryMint,
            Color(0xFF7BF1DD),
            AppColors.primaryMint,
          ],
          const [0, 0.6, 1],
          TileMode.clamp,
          -math.pi / 2,
          math.pi * 1.5,
        ),
    );
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.fraction != fraction;
}
