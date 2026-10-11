import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../animations.dart';
import 'holo_body.dart';
import 'holo_pose.dart';

export 'holo_pose.dart' show HoloExercise, HoloFault;

/// The colour of a hologram: what it is telling the patient.
enum HoloTone {
  /// The pearl-white figure used for the app's mascot and guides.
  neutral,

  /// Teal and mint: the right way to move.
  correct,

  /// RED: stop, this could hurt.
  red,

  /// AMBER: form to correct.
  amber,

  /// INFO: a small thing to refine.
  info,
}

/// A small mark in the corner of a highlighted joint.
enum HoloMark { none, cross, tick }

class _Palette {
  const _Palette(this.light, this.base, this.deep, this.glow, this.joint);

  final Color light;
  final Color base;
  final Color deep;
  final Color glow;
  final Color joint;

  static _Palette of(HoloTone tone) => switch (tone) {
    HoloTone.neutral => const _Palette(
      Color(0xFFFFFFFF),
      Color(0xFFE2E7F3),
      Color(0xFF8592B5),
      Color(0xFF8FD8F2),
      Color(0xFF00BFA5),
    ),
    HoloTone.correct => const _Palette(
      Color(0xFFF2FFFC),
      Color(0xFFA6EDE2),
      Color(0xFF1F7F7A),
      Color(0xFF00BFA5),
      Color(0xFF00E5C0),
    ),
    HoloTone.red => const _Palette(
      Color(0xFFFFF5F5),
      Color(0xFFF6B0B0),
      Color(0xFFA52A2A),
      Color(0xFFFF5252),
      Color(0xFFFF6E6E),
    ),
    HoloTone.amber => const _Palette(
      Color(0xFFFFF9F0),
      Color(0xFFF9CF95),
      Color(0xFFB0620F),
      Color(0xFFFF9800),
      Color(0xFFFFB74D),
    ),
    HoloTone.info => const _Palette(
      Color(0xFFF3F8FF),
      Color(0xFFB0CFF6),
      Color(0xFF2B62AE),
      Color(0xFF42A5F5),
      Color(0xFF64B5F6),
    ),
  };
}

/// Tells the holograms below it whether they stand on a dark background.
/// On dark they are drawn as light: see-through in the middle and bright at
/// the edges. On a light background they are a solid, softly lit body.
class HoloBackdrop extends InheritedWidget {
  const HoloBackdrop({super.key, required this.dark, required super.child});

  final bool dark;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HoloBackdrop>()?.dark ?? false;

  @override
  bool updateShouldNotify(HoloBackdrop old) => old.dark != dark;
}

/// A 3D holographic figure performing an exercise on a glowing pedestal.
///
/// It loops the movement from the resting position to its peak while
/// slowly turning, so the patient sees the motion from more than one side.
/// With a [fault] it performs the movement the wrong way, highlights the
/// joint at fault and draws the line it should follow. When motion is off it
/// holds the peak of the movement, the position that teaches the most.
class HoloFigure extends StatefulWidget {
  const HoloFigure({
    super.key,
    this.exercise = HoloExercise.stand,
    this.fault = HoloFault.none,
    this.tone = HoloTone.correct,
    this.correctVersion = false,
    this.animate = true,
    this.pedestal = true,
    this.guides = true,
    this.mark = HoloMark.none,
    this.turn = 22,
    this.cycle = const Duration(milliseconds: 2800),
    this.onDark,
    this.semanticLabel,
  });

  final HoloExercise exercise;

  /// The fault to act out, or, with [correctVersion], the fault this figure
  /// is the correct counterpart of (same view, same guide lines).
  final HoloFault fault;
  final HoloTone tone;
  final bool correctVersion;
  final bool animate;
  final bool pedestal;
  final bool guides;
  final HoloMark mark;

  /// How far it turns either way while animating, degrees.
  final double turn;

  /// One repetition of the movement.
  final Duration cycle;

  /// Whether it stands on a dark background; taken from the nearest
  /// [HoloBackdrop] when not given.
  final bool? onDark;
  final String? semanticLabel;

  @override
  State<HoloFigure> createState() => _HoloFigureState();
}

class _HoloFigureState extends State<HoloFigure>
    with SingleTickerProviderStateMixin {
  // One long loop drives everything; the movement and the turn run at
  // their own pace inside it.
  static const _loop = Duration(seconds: 24);
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: _loop,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(HoloFigure old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final moving = widget.animate && Motion.of(context);
    if (moving && !_clock.isAnimating) {
      _clock.repeat();
    } else if (!moving && _clock.isAnimating) {
      _clock.stop();
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scene = widget.correctVersion
        ? HoloScene.correctFor(widget.exercise, widget.fault)
        : HoloScene.of(widget.exercise, widget.fault);
    final moving = widget.animate && Motion.of(context);
    return Semantics(
      image: true,
      label: widget.semanticLabel,
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _HoloPainter(
            scene: scene,
            palette: _Palette.of(widget.tone),
            clock: moving ? _clock : null,
            loopSeconds: _loop.inMilliseconds / 1000,
            cycleSeconds: widget.cycle.inMilliseconds / 1000,
            turn: widget.turn,
            pedestal: widget.pedestal,
            guides: widget.guides,
            mark: widget.mark,
            standing: widget.exercise == HoloExercise.stand,
            dark: widget.onDark ?? HoloBackdrop.of(context),
          ),
        ),
      ),
    );
  }
}

class _Projected {
  const _Projected(this.offset, this.depth, this.scale);

  final Offset offset;

  /// Larger is nearer the viewer.
  final double depth;

  /// Pixels per world unit at this depth.
  final double scale;
}

class _Segment {
  const _Segment(this.a, this.b, this.ra, this.rb);

  final Joint a;
  final Joint b;
  final double ra;
  final double rb;
}

const _segments = [
  _Segment(Joint.leftHip, Joint.leftKnee, 0.088, 0.062),
  _Segment(Joint.rightHip, Joint.rightKnee, 0.088, 0.062),
  _Segment(Joint.leftKnee, Joint.leftAnkle, 0.06, 0.04),
  _Segment(Joint.rightKnee, Joint.rightAnkle, 0.06, 0.04),
  _Segment(Joint.leftAnkle, Joint.leftToe, 0.042, 0.032),
  _Segment(Joint.rightAnkle, Joint.rightToe, 0.042, 0.032),
  _Segment(Joint.leftHip, Joint.rightHip, 0.07, 0.07),
  _Segment(Joint.pelvis, Joint.chest, 0.115, 0.125),
  _Segment(Joint.leftShoulder, Joint.rightShoulder, 0.068, 0.068),
  _Segment(Joint.chest, Joint.neck, 0.05, 0.045),
  _Segment(Joint.leftShoulder, Joint.leftElbow, 0.058, 0.046),
  _Segment(Joint.rightShoulder, Joint.rightElbow, 0.058, 0.046),
  _Segment(Joint.leftElbow, Joint.leftWrist, 0.044, 0.033),
  _Segment(Joint.rightElbow, Joint.rightWrist, 0.044, 0.033),
];

const _trackedJoints = [
  Joint.leftShoulder,
  Joint.rightShoulder,
  Joint.leftElbow,
  Joint.rightElbow,
  Joint.leftWrist,
  Joint.rightWrist,
  Joint.leftHip,
  Joint.rightHip,
  Joint.leftKnee,
  Joint.rightKnee,
  Joint.leftAnkle,
  Joint.rightAnkle,
];

const _wire = [
  (Joint.neck, Joint.chest),
  (Joint.chest, Joint.pelvis),
  (Joint.leftShoulder, Joint.rightShoulder),
  (Joint.leftHip, Joint.rightHip),
  (Joint.leftShoulder, Joint.leftElbow),
  (Joint.leftElbow, Joint.leftWrist),
  (Joint.rightShoulder, Joint.rightElbow),
  (Joint.rightElbow, Joint.rightWrist),
  (Joint.leftHip, Joint.leftKnee),
  (Joint.leftKnee, Joint.leftAnkle),
  (Joint.rightHip, Joint.rightKnee),
  (Joint.rightKnee, Joint.rightAnkle),
];

/// Paints a [HoloScene].
class _HoloPainter extends CustomPainter {
  _HoloPainter({
    required this.scene,
    required _Palette palette,
    required this.clock,
    required this.loopSeconds,
    required this.cycleSeconds,
    required this.turn,
    required this.pedestal,
    required this.guides,
    required this.mark,
    required this.standing,
    required this.dark,
  }) : _palette = palette,
       super(repaint: clock);

  final HoloScene scene;
  final _Palette _palette;
  final Animation<double>? clock;
  final double loopSeconds;
  final double cycleSeconds;
  final double turn;
  final bool pedestal;
  final bool guides;
  final HoloMark mark;
  final bool standing;
  final bool dark;

  static const _cameraTilt = 11.0;

  /// Where the light comes from, as the viewer sees it: above, to the left
  /// and in front.
  static const _light = Vec3(-0.42, 0.62, 0.66);
  static const _focal = 5.2;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final seconds = (clock?.value ?? 0) * loopSeconds;
    final moving = clock != null;

    // Where in the repetition: rest, down, hold briefly, back up.
    final double phase;
    if (!moving) {
      phase = standing ? 0 : 1;
    } else if (standing) {
      phase = 0;
    } else {
      final p = (seconds % cycleSeconds) / cycleSeconds;
      final wave = (1 - math.cos(p * 2 * math.pi)) / 2;
      phase = Curves.easeInOut.transform((wave * 1.15).clamp(0.0, 1.0));
    }
    final yaw =
        scene.yaw +
        (moving ? turn * math.sin(seconds * 2 * math.pi / loopSeconds * 2) : 0);
    final breathe = moving ? math.sin(seconds * 2 * math.pi / 4) : 0.0;

    final joints = skeletonFor(BodyPose.lerp(scene.rest, scene.peak, phase));

    // Fit: the figure's height and the movement's width.
    final height = size.height;
    final width = size.width;
    final unit = math.min(
      height * 0.7 / 1.95,
      width * 0.86 / (scene.span + 0.35),
    );
    final groundY = height * (pedestal ? 0.82 : 0.9);
    final centre = _centre;

    // The turn and the camera's tilt as one change of axes, worked out once
    // for the frame rather than for each of the body's points.
    Vec3 turned(Vec3 v) =>
        v.rotate(Vec3.up, yaw).rotate(Vec3.right, -_cameraTilt);
    final ax = turned(Vec3.right);
    final ay = turned(Vec3.up);
    final az = turned(Vec3.forward);
    Vec3 view(Vec3 v) => ax * v.x + ay * v.y + az * v.z;

    _Projected project(Vec3 p) {
      final v = view(p - Vec3(centre.x, 0, centre.z));
      final k = _focal / (_focal - v.z);
      return _Projected(
        Offset(width / 2 + v.x * unit * k, groundY - v.y * unit * k),
        v.z,
        unit * k,
      );
    }

    final points = {
      for (final entry in joints.entries) entry.key: project(entry.value),
    };

    if (pedestal) {
      _paintBeam(canvas, size, project, points, unit, seconds, moving);
      _paintPedestal(canvas, project, unit, seconds, moving);
    }
    _paintShadow(canvas, points, unit);
    _paintBody(canvas, points, joints, project, view, unit);
    _paintWireframe(canvas, points, seconds, moving, breathe);
    if (guides) _paintGuides(canvas, points, joints, project);
    _paintHighlights(canvas, points, seconds, moving);
    if (moving) _paintScan(canvas, size, points, seconds);
  }

  static Vec3 _centreOf(HoloScene scene) {
    var minX = double.infinity, maxX = -double.infinity;
    var minZ = double.infinity, maxZ = -double.infinity;
    for (final pose in [scene.rest, scene.peak]) {
      for (final p in skeletonFor(pose).values) {
        minX = math.min(minX, p.x);
        maxX = math.max(maxX, p.x);
        minZ = math.min(minZ, p.z);
        maxZ = math.max(maxZ, p.z);
      }
    }
    return Vec3((minX + maxX) / 2, 0, (minZ + maxZ) / 2);
  }

  late final Vec3 _centre = _centreOf(scene);

  double get _radius => 0.42 + scene.span * 0.32;

  List<Offset> _ring(
    _Projected Function(Vec3) project,
    double radius,
    double y, [
    int steps = 72,
  ]) {
    final centre = _centre;
    return [
      for (var i = 0; i <= steps; i++)
        project(
          Vec3(
            centre.x + radius * math.cos(i * 2 * math.pi / steps),
            y,
            centre.z + radius * math.sin(i * 2 * math.pi / steps),
          ),
        ).offset,
    ];
  }

  void _paintBeam(
    Canvas canvas,
    Size size,
    _Projected Function(Vec3) project,
    Map<Joint, _Projected> points,
    double unit,
    double seconds,
    bool moving,
  ) {
    final ring = _ring(project, _radius * 0.92, 0);
    var left = double.infinity, right = -double.infinity, base = 0.0;
    for (final p in ring) {
      left = math.min(left, p.dx);
      right = math.max(right, p.dx);
      base = math.max(base, p.dy);
    }
    var top = double.infinity;
    for (final p in points.values) {
      top = math.min(top, p.offset.dy);
    }
    top -= unit * 0.25;
    final mid = (left + right) / 2;
    final spread = (right - left) / 2;
    final beam = Path()
      ..moveTo(left, base - unit * 0.05)
      ..lineTo(mid - spread * 0.78, top)
      ..lineTo(mid + spread * 0.78, top)
      ..lineTo(right, base - unit * 0.05)
      ..close();
    canvas.drawPath(
      beam,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, base),
          Offset(0, top),
          [
            _palette.glow.withValues(alpha: 0.26),
            _palette.glow.withValues(alpha: 0.07),
            _palette.glow.withValues(alpha: 0),
          ],
          const [0, 0.55, 1],
        ),
    );

    // Motes of light drifting up the beam.
    if (moving) {
      final dot = Paint()..color = _palette.light;
      for (var i = 0; i < 14; i++) {
        final seed = i * 0.6180339;
        final rise = ((seconds * 0.22 + seed) % 1.0);
        final x = mid + spread * 0.85 * math.sin(seed * 9.1 + seconds * 0.3);
        final y = base - (base - top) * rise;
        dot.color = _palette.light.withValues(
          alpha: 0.7 * math.sin(rise * math.pi),
        );
        canvas.drawCircle(Offset(x, y), 1.2 + (i % 3) * 0.6, dot);
      }
    }
  }

  void _paintPedestal(
    Canvas canvas,
    _Projected Function(Vec3) project,
    double unit,
    double seconds,
    bool moving,
  ) {
    final r = _radius;
    final top = _ring(project, r, 0);
    final bottom = _ring(project, r, -0.09);

    // The side of the disc: the near half of the band between the rims.
    final side = Path()..addPolygon([...top, ...bottom.reversed], true);
    var minY = double.infinity, maxY = -double.infinity;
    for (final p in bottom) {
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    canvas.drawPath(
      side,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, minY),
          Offset(0, maxY),
          dark
              ? [
                  _palette.glow.withValues(alpha: 0.6),
                  _palette.deep.withValues(alpha: 0.55),
                  const Color(0xFF07131D),
                ]
              : [
                  const Color(0xFFF7F9FC),
                  _palette.base,
                  _palette.deep.withValues(alpha: 0.9),
                ],
          const [0, 0.6, 1],
        ),
    );

    final face = Path()..addPolygon(top, true);
    final bounds = face.getBounds();
    canvas.drawPath(
      face,
      Paint()
        ..shader = ui.Gradient.radial(
          bounds.center,
          bounds.width / 2,
          dark
              ? [
                  _palette.glow.withValues(alpha: 0.34),
                  _palette.glow.withValues(alpha: 0.08),
                  _palette.glow.withValues(alpha: 0.24),
                ]
              : [
                  Colors.white,
                  const Color(0xFFF2F5FA),
                  Color.lerp(_palette.base, Colors.white, 0.4)!,
                ],
          const [0, 0.7, 1],
        ),
    );

    // Glowing rim and an inner ring of light.
    canvas.drawPath(
      face,
      Paint()
        ..color = _palette.glow.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawPath(
      face,
      Paint()
        ..color = _palette.glow.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    final inner = Path()..addPolygon(_ring(project, r * 0.72, 0.001), true);
    canvas.drawPath(
      inner,
      Paint()
        ..color = _palette.glow.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // A dashed ring that turns slowly.
    final dashes = _ring(project, r * 0.86, 0.001, 96);
    final spin = moving ? (seconds * 6).floor() % 6 : 0;
    final dash = Paint()
      ..color = _palette.glow.withValues(alpha: 0.75)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    for (var i = spin; i < dashes.length - 1; i += 6) {
      canvas.drawLine(dashes[i], dashes[i + 1], dash);
    }
  }

  void _paintShadow(Canvas canvas, Map<Joint, _Projected> points, double unit) {
    final feet = [
      points[Joint.leftAnkle]!.offset,
      points[Joint.rightAnkle]!.offset,
      points[Joint.leftToe]!.offset,
      points[Joint.rightToe]!.offset,
    ];
    var minX = double.infinity, maxX = -double.infinity, y = 0.0;
    for (final p in feet) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      y = math.max(y, p.dy);
    }
    final rect = Rect.fromLTRB(
      minX - unit * 0.12,
      y - unit * 0.03,
      maxX + unit * 0.12,
      y + unit * 0.06,
    );
    canvas.drawOval(
      rect,
      Paint()
        ..color = _palette.deep.withValues(alpha: 0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
  }

  void _paintBody(
    Canvas canvas,
    Map<Joint, _Projected> points,
    Map<Joint, Vec3> joints,
    _Projected Function(Vec3) project,
    Vec3 Function(Vec3) view,
    double unit,
  ) {
    // The aura first, under everything.
    final aura = Paint()
      ..color = _palette.glow.withValues(alpha: dark ? 0.42 : 0.3)
      ..strokeCap = StrokeCap.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, dark ? 14 : 9);
    for (final s in _segments) {
      final a = points[s.a]!;
      final b = points[s.b]!;
      aura.strokeWidth = (s.ra + s.rb) * a.scale + 10;
      canvas.drawLine(a.offset, b.offset, aura);
    }
    final head = points[Joint.head]!;
    canvas.drawCircle(
      head.offset,
      0.116 * head.scale + 6,
      aura..style = PaintingStyle.fill,
    );

    // The scan mesh is only worth drawing when the figure is large enough
    // for its lines to be told apart.
    final meshStrength = ((unit - 46) / 70).clamp(0.0, 1.0);
    const around = BodyPart.around;
    final drawn = <(double, ui.Vertices, Path)>[];
    for (final part in buildBody(joints)) {
      final count = part.positions.length;
      final xy = Float32List(count * 2);
      final colors = Int32List(count);
      final facing = Float32List(count);
      var depth = 0.0;
      for (var i = 0; i < count; i++) {
        final at = project(part.positions[i]);
        xy[i * 2] = at.offset.dx;
        xy[i * 2 + 1] = at.offset.dy;
        depth += at.depth;
        final normal = view(part.normals[i]);
        facing[i] = normal.z;
        colors[i] = _shade(normal).toARGB32();
      }
      final indices = <int>[];
      final mesh = Path();
      for (var ring = 0; ring < part.rings - 1; ring++) {
        for (var k = 0; k < around; k++) {
          final a = ring * around + k;
          final b = ring * around + (k + 1) % around;
          final c = a + around;
          final d = b + around;
          // The far side of each part is left out: it is hidden by the
          // near side, or would only muddy a see-through body.
          if (facing[a] + facing[b] + facing[c] + facing[d] <= 0) continue;
          indices
            ..add(a)
            ..add(b)
            ..add(c)
            ..add(b)
            ..add(d)
            ..add(c);
          if (meshStrength > 0) {
            mesh
              ..moveTo(xy[a * 2], xy[a * 2 + 1])
              ..lineTo(xy[b * 2], xy[b * 2 + 1]);
            if (k.isEven) {
              mesh
                ..moveTo(xy[a * 2], xy[a * 2 + 1])
                ..lineTo(xy[c * 2], xy[c * 2 + 1]);
            }
          }
        }
      }
      if (indices.isEmpty) continue;
      drawn.add((
        depth / count,
        ui.Vertices.raw(
          VertexMode.triangles,
          xy,
          colors: colors,
          indices: Uint16List.fromList(indices),
        ),
        mesh,
      ));
    }
    // Painter's algorithm: the furthest parts first.
    drawn.sort((x, y) => x.$1.compareTo(y.$1));

    final surface = Paint();
    final wire = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = dark ? 0.7 : 0.55
      ..color = (dark ? _palette.light : _palette.deep).withValues(
        alpha: (dark ? 0.34 : 0.2) * meshStrength,
      );
    for (final (_, vertices, mesh) in drawn) {
      // BlendMode.dst keeps the colour worked out for each point.
      canvas.drawVertices(vertices, BlendMode.dst, surface);
      if (meshStrength > 0) canvas.drawPath(mesh, wire);
    }
  }

  /// The colour of the body where its surface faces [normal], as seen by the
  /// viewer.
  Color _shade(Vec3 normal) {
    final edge = 1 - normal.z.abs().clamp(0.0, 1.0);
    final lit = math.max(0.0, normal.dot(_light));
    if (dark) {
      // Light, not matter: faint where you look straight through it, bright
      // where the surface turns away.
      final rim = math.pow(edge, 1.5).toDouble();
      final body = Color.lerp(_palette.deep, _palette.glow, 0.3 + 0.5 * lit)!;
      return Color.lerp(
        body,
        _palette.light,
        rim * 0.9,
      )!.withValues(alpha: (0.26 + 0.22 * lit + 0.55 * rim).clamp(0.0, 1.0));
    }
    final rim = math.pow(edge, 2.2).toDouble();
    final body = Color.lerp(
      _palette.base,
      Colors.white,
      (0.12 + 0.88 * lit).clamp(0.0, 1.0),
    )!;
    return Color.lerp(body, _palette.deep, rim * 0.9)!.withValues(alpha: 0.97);
  }

  void _paintWireframe(
    Canvas canvas,
    Map<Joint, _Projected> points,
    double seconds,
    bool moving,
    double breathe,
  ) {
    final line = Paint()
      ..color = _palette.joint.withValues(alpha: 0.55)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    for (final (a, b) in _wire) {
      canvas.drawLine(points[a]!.offset, points[b]!.offset, line);
    }
    for (final (i, joint) in _trackedJoints.indexed) {
      final p = points[joint]!.offset;
      // Each tracking point breathes on its own beat.
      final pulse = moving
          ? 0.7 + 0.3 * (0.5 + 0.5 * math.sin(seconds * math.pi + i * 0.9))
          : 1.0;
      canvas.drawCircle(
        p,
        5.5,
        Paint()
          ..color = _palette.joint.withValues(alpha: 0.35 * pulse)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      canvas.drawCircle(
        p,
        2.6,
        Paint()..color = Colors.white.withValues(alpha: pulse),
      );
      canvas.drawCircle(
        p,
        2.6,
        Paint()
          ..color = _palette.joint.withValues(alpha: pulse)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
  }

  void _paintGuides(
    Canvas canvas,
    Map<Joint, _Projected> points,
    Map<Joint, Vec3> joints,
    _Projected Function(Vec3) project,
  ) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.95)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final glow = Paint()
      ..color = const Color(0xFF00E5A0).withValues(alpha: 0.7)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    for (final guide in scene.guides) {
      final from = points[guide.from]!.offset;
      final Offset to;
      if (guide.vertical) {
        to = project(joints[guide.from]! + const Vec3(0, 0.75, 0)).offset;
      } else {
        to = points[guide.to!]!.offset;
      }
      _dashed(canvas, from, to, glow);
      _dashed(canvas, from, to, paint);
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    final d = b - a;
    final length = d.distance;
    if (length == 0) return;
    final step = d / length;
    for (var s = 0.0; s < length; s += 9) {
      canvas.drawLine(a + step * s, a + step * math.min(s + 5, length), paint);
    }
  }

  void _paintHighlights(
    Canvas canvas,
    Map<Joint, _Projected> points,
    double seconds,
    bool moving,
  ) {
    final pulse = moving
        ? 0.5 + 0.5 * math.sin(seconds * 2 * math.pi / 1.2)
        : 1.0;
    for (final joint in scene.highlights) {
      final p = points[joint]!;
      final r = 0.075 * p.scale + 6;
      canvas.drawCircle(
        p.offset,
        r * (1.25 + 0.35 * pulse),
        Paint()
          ..color = _palette.glow.withValues(alpha: 0.28 * pulse + 0.1)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
      canvas.drawCircle(
        p.offset,
        r * (1 + 0.18 * pulse),
        Paint()
          ..color = _palette.glow
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2,
      );
      canvas.drawCircle(p.offset, 4, Paint()..color = _palette.glow);
      canvas.drawCircle(p.offset, 2, Paint()..color = Colors.white);
    }
    if (mark != HoloMark.none && scene.highlights.isNotEmpty) {
      final p = points[scene.highlights.first]!;
      final at =
          p.offset + Offset(0.075 * p.scale + 16, -(0.075 * p.scale + 14));
      final color = mark == HoloMark.cross
          ? const Color(0xFFC62828)
          : const Color(0xFF2E7D32);
      canvas.drawCircle(
        at,
        11,
        Paint()
          ..color = color.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawCircle(at, 10, Paint()..color = color);
      canvas.drawCircle(
        at,
        10,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      final stroke = Paint()
        ..color = Colors.white
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      if (mark == HoloMark.cross) {
        canvas.drawLine(
          at + const Offset(-4, -4),
          at + const Offset(4, 4),
          stroke,
        );
        canvas.drawLine(
          at + const Offset(4, -4),
          at + const Offset(-4, 4),
          stroke,
        );
      } else {
        canvas.drawPath(
          Path()
            ..moveTo(at.dx - 4.5, at.dy)
            ..lineTo(at.dx - 1.2, at.dy + 3.5)
            ..lineTo(at.dx + 4.8, at.dy - 3.6),
          stroke..strokeJoin = StrokeJoin.round,
        );
      }
    }
  }

  void _paintScan(
    Canvas canvas,
    Size size,
    Map<Joint, _Projected> points,
    double seconds,
  ) {
    var top = double.infinity, bottom = -double.infinity;
    var left = double.infinity, right = -double.infinity;
    for (final p in points.values) {
      top = math.min(top, p.offset.dy);
      bottom = math.max(bottom, p.offset.dy);
      left = math.min(left, p.offset.dx);
      right = math.max(right, p.offset.dx);
    }
    top -= 20;
    final t = (seconds % 3.2) / 3.2;
    final y = top + (bottom - top) * t;
    final band = Rect.fromLTRB(left - 14, y - 7, right + 14, y + 7);
    canvas.drawRect(
      band,
      Paint()
        ..shader = ui.Gradient.linear(band.topCenter, band.bottomCenter, [
          _palette.glow.withValues(alpha: 0),
          _palette.glow.withValues(alpha: 0.16),
          _palette.glow.withValues(alpha: 0),
        ]),
    );
  }

  @override
  bool shouldRepaint(_HoloPainter old) =>
      old.scene != scene ||
      old._palette != _palette ||
      old.clock != clock ||
      old.mark != mark ||
      old.pedestal != pedestal ||
      old.guides != guides ||
      old.dark != dark;
}

/// A hologram on its own softly lit stage: a rounded panel with a gradient
/// wash, for thumbnails and comparisons.
class HoloStage extends StatelessWidget {
  const HoloStage({
    super.key,
    required this.child,
    this.tint,
    this.dark = false,
    this.radius = 20,
    this.label,
    this.labelColor,
  });

  final Widget child;
  final Color? tint;
  final bool dark;
  final double radius;
  final Widget? label;
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    final wash = tint;
    final gradient = dark
        ? LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(const Color(0xFF13293A), wash, 0.18)!,
              const Color(0xFF0B1A27),
            ],
          )
        : wash == null
        ? const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFEAF0FB), Color(0xFFE3F4F3), Color(0xFFF1ECFA)],
          )
        : LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(Colors.white, wash, 0.10)!,
              Color.lerp(Colors.white, wash, 0.22)!,
            ],
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: gradient),
        child: Stack(
          fit: StackFit.expand,
          children: [
            HoloBackdrop(dark: dark, child: child),
            if (label != null)
              Positioned(left: 10, top: 10, right: 10, child: label!),
          ],
        ),
      ),
    );
  }
}
