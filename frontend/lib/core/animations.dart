import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The app's motion system: durations, curves and the small animated
/// building blocks every screen shares.
///
/// Decorative motion (holograms turning, pulses, count-ups, slide-ins) is
/// switched off when the person has asked their device to reduce motion, and
/// can be switched off for the whole app with [Motion.enabled], which the
/// widget tests do so every screen settles at once.
abstract final class Motion {
  /// False renders every decorative animation at its final state.
  static bool enabled = true;

  static const badgeSlide = Duration(milliseconds: 280);
  static const pulse = Duration(milliseconds: 1200);
  static const checkDraw = Duration(milliseconds: 400);
  static const checkStagger = Duration(milliseconds: 200);
  static const scoreCount = Duration(milliseconds: 1200);
  static const repPop = Duration(milliseconds: 200);
  static const jointPulse = Duration(milliseconds: 2000);
  static const celebrate = Duration(milliseconds: 800);

  static const easeOutCubic = Curves.easeOutCubic;
  static const easeOutExpo = Curves.easeOutExpo;

  /// Whether decorative motion should play in this part of the tree.
  static bool of(BuildContext context) =>
      enabled && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
}

/// Slides its child up from below and fades it in when first built, or when
/// its key changes (pass a new key for each new piece of feedback).
class SlideUpIn extends StatelessWidget {
  const SlideUpIn({
    super.key,
    required this.child,
    this.duration = Motion.badgeSlide,
    this.delay = Duration.zero,
    this.offset = 24,
  });

  final Widget child;
  final Duration duration;
  final Duration delay;

  /// How far below its place it starts, in logical pixels.
  final double offset;

  @override
  Widget build(BuildContext context) {
    if (!Motion.of(context)) return child;
    final total = duration + delay;
    final start = total.inMicroseconds == 0
        ? 0.0
        : delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      builder: (context, value, child) {
        final t = Motion.easeOutCubic.transform(
          start >= 1 ? 1 : ((value - start) / (1 - start)).clamp(0.0, 1.0),
        );
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, offset * (1 - t)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// Repeats a gentle scale pulse: 1.0 to [scale] and back.
class Pulse extends StatefulWidget {
  const Pulse({
    super.key,
    required this.child,
    this.scale = 1.08,
    this.duration = Motion.pulse,
  });

  final Widget child;
  final double scale;
  final Duration duration;

  @override
  State<Pulse> createState() => _PulseState();
}

class _PulseState extends State<Pulse> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.of(context)) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final wave = (1 - math.cos(_controller.value * 2 * math.pi)) / 2;
        return Transform.scale(
          scale: 1 + (widget.scale - 1) * wave,
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// A continuously repeating 0..1 value for painters, or a fixed one when
/// motion is off.
class Ticking extends StatefulWidget {
  const Ticking({
    super.key,
    required this.builder,
    this.period = const Duration(seconds: 2),
    this.restingValue = 0,
  });

  final Widget Function(BuildContext context, double value) builder;
  final Duration period;
  final double restingValue;

  @override
  State<Ticking> createState() => _TickingState();
}

class _TickingState extends State<Ticking> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: widget.period,
    value: widget.restingValue,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.of(context)) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller
        ..stop()
        ..value = widget.restingValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) => widget.builder(context, _controller.value),
  );
}

/// Counts a number up from zero the first time it is shown.
class CountUp extends StatelessWidget {
  const CountUp({
    super.key,
    required this.value,
    required this.builder,
    this.duration = Motion.scoreCount,
  });

  final int value;
  final Widget Function(BuildContext context, int shown) builder;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    if (!Motion.of(context)) return builder(context, value);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.toDouble()),
      duration: duration,
      curve: Motion.easeOutExpo,
      builder: (context, shown, _) => builder(context, shown.round()),
    );
  }
}

/// Pops its child (scale 1.0 to 1.15 and back) whenever [value] changes,
/// for the repetition counter.
class PopOnChange extends StatelessWidget {
  const PopOnChange({super.key, required this.value, required this.child});

  final Object value;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Motion.of(context)) return child;
    return TweenAnimationBuilder<double>(
      key: ValueKey(value),
      tween: Tween(begin: 0, end: 1),
      duration: Motion.repPop,
      curve: Curves.easeOut,
      builder: (context, t, child) => Transform.scale(
        scale: 1 + 0.15 * math.sin(t * math.pi),
        child: child,
      ),
      child: child,
    );
  }
}

/// A circle that draws itself in, then a tick, then a small burst of dots:
/// the "session complete" moment.
class CelebrationCheck extends StatelessWidget {
  const CelebrationCheck({
    super.key,
    this.size = 72,
    this.color = Colors.white,
    this.burstColor = const Color(0xFF00BFA5),
  });

  final double size;
  final Color color;
  final Color burstColor;

  @override
  Widget build(BuildContext context) {
    Widget draw(double t) => CustomPaint(
      size: Size.square(size),
      painter: _CheckPainter(t, color, burstColor),
    );
    if (!Motion.of(context)) return draw(1);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.celebrate * 1.6,
      builder: (context, t, _) => draw(t),
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.t, this.color, this.burst);

  final double t;
  final Color color;
  final Color burst;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * 0.36;
    final ring = (t / 0.5).clamp(0.0, 1.0);
    final tick = ((t - 0.4) / 0.25).clamp(0.0, 1.0);
    final pop = ((t - 0.6) / 0.4).clamp(0.0, 1.0);

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = color.withValues(alpha: 0.14 * ring),
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * Curves.easeOut.transform(ring),
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.shortestSide * 0.06
        ..strokeCap = StrokeCap.round,
    );
    if (tick > 0) {
      final a = center + Offset(-radius * 0.45, radius * 0.02);
      final b = center + Offset(-radius * 0.1, radius * 0.36);
      final c = center + Offset(radius * 0.5, -radius * 0.32);
      final path = Path()..moveTo(a.dx, a.dy);
      final first = (tick / 0.4).clamp(0.0, 1.0);
      path.lineTo(a.dx + (b.dx - a.dx) * first, a.dy + (b.dy - a.dy) * first);
      if (tick > 0.4) {
        final second = ((tick - 0.4) / 0.6).clamp(0.0, 1.0);
        path.lineTo(
          b.dx + (c.dx - b.dx) * second,
          b.dy + (c.dy - b.dy) * second,
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = size.shortestSide * 0.07
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    if (pop > 0 && pop < 1) {
      final fade = 1 - pop;
      for (var i = 0; i < 5; i++) {
        final angle = -math.pi / 2 + i * 2 * math.pi / 5;
        final distance = radius * (1.15 + 0.45 * Curves.easeOut.transform(pop));
        canvas.drawCircle(
          center + Offset(math.cos(angle), math.sin(angle)) * distance,
          size.shortestSide * 0.04 * fade + 1,
          Paint()..color = burst.withValues(alpha: fade),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.t != t;
}

/// A teal shimmer sweep over loading placeholders.
class Shimmer extends StatelessWidget {
  const Shimmer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Ticking(
      period: const Duration(milliseconds: 1400),
      restingValue: 0.5,
      builder: (context, t) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (bounds) => LinearGradient(
          begin: Alignment(-1.5 + 3 * t, -0.3),
          end: Alignment(-0.5 + 3 * t, 0.3),
          colors: const [
            Color(0xFFE0F2F1),
            Color(0xFFB2DFDB),
            Color(0xFFE0F2F1),
          ],
        ).createShader(bounds),
        child: child,
      ),
    );
  }
}
