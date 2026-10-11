import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The background behind the app's light pages: a wash from cool ice to a
/// warm blush with two soft pools of colour, in place of a flat white. It
/// stays pale enough for dark text and white cards to sit on it.
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFDDEFF0), Color(0xFFEDF5F3), Color(0xFFF5E9DF)],
          stops: [0, 0.5, 1],
        ),
      ),
      child: CustomPaint(painter: const _PoolsPainter(), child: child),
    );
  }
}

class _PoolsPainter extends CustomPainter {
  const _PoolsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    void pool(Offset centre, double radius, Color color) {
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

    final reach = size.longestSide;
    pool(
      Offset(size.width * 0.92, size.height * 0.04),
      reach * 0.5,
      AppColors.aqua.withValues(alpha: 0.5),
    );
    pool(
      Offset(size.width * 0.08, size.height * 0.96),
      reach * 0.45,
      AppColors.sand.withValues(alpha: 0.55),
    );
    pool(
      Offset(size.width * 0.5, size.height * 0.45),
      reach * 0.35,
      Colors.white.withValues(alpha: 0.5),
    );
  }

  @override
  bool shouldRepaint(_PoolsPainter old) => false;
}
