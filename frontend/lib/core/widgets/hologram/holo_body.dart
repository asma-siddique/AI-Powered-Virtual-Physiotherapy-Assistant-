import 'dart:math' as math;

import 'holo_pose.dart';

/// The surface of the hologram's body: a set of closed tubes (trunk, limbs,
/// head, hands, feet) shaped like the parts of a person and wrapped around
/// the skeleton, so the figure reads as a body rather than as sticks.
///
/// Each part is a grid of points, [rings] along it and [around] round it,
/// with the outward direction at every point for shading.
class BodyPart {
  BodyPart(this.positions, this.normals, this.rings);

  /// How many points go round each ring.
  static const around = 16;

  /// Ring after ring, [around] points each.
  final List<Vec3> positions;
  final List<Vec3> normals;
  final int rings;
}

class _Ring {
  const _Ring(this.centre, this.u, this.v, this.ru, this.rv);

  final Vec3 centre;

  /// The two axes of the cross-section, at right angles to the part.
  final Vec3 u;
  final Vec3 v;
  final double ru;
  final double rv;
}

BodyPart _part(List<_Ring> rings) {
  const n = BodyPart.around;
  final positions = <Vec3>[];
  for (final ring in rings) {
    for (var k = 0; k < n; k++) {
      final angle = 2 * math.pi * k / n;
      positions.add(
        ring.centre +
            ring.u * (ring.ru * math.cos(angle)) +
            ring.v * (ring.rv * math.sin(angle)),
      );
    }
  }
  Vec3 at(int i, int k) => positions[i * n + (k % n + n) % n];

  final normals = <Vec3>[];
  for (var i = 0; i < rings.length; i++) {
    final before = math.max(i - 1, 0);
    final after = math.min(i + 1, rings.length - 1);
    // Where the surface closes to a point there is no ring to measure, so
    // the outward direction is along the part itself.
    final along = (rings[after].centre - rings[before].centre).normalized;
    final pole = i == 0 ? along * -1 : along;
    for (var k = 0; k < n; k++) {
      final round = at(i, k + 1) - at(i, k - 1);
      final length = at(after, k) - at(before, k);
      var normal = round.cross(length);
      if (normal.length < 1e-7) {
        normals.add(pole);
        continue;
      }
      normal = normal.normalized;
      final outward = at(i, k) - rings[i].centre;
      normals.add(normal.dot(outward) < 0 ? normal * -1 : normal);
    }
  }
  return BodyPart(positions, normals, rings.length);
}

/// A unit vector at right angles to [dir], as close to [hint] as possible.
Vec3 _across(Vec3 dir, Vec3 hint, Vec3 fallback) {
  var side = hint - dir * hint.dot(dir);
  if (side.length < 0.3) side = fallback - dir * fallback.dot(dir);
  return side.normalized;
}

typedef _Profile = List<(double t, double ru, double rv)>;

(double, double) _radii(_Profile profile, double t) {
  for (var i = 1; i < profile.length; i++) {
    final (t1, u1, v1) = profile[i];
    if (t <= t1) {
      final (t0, u0, v0) = profile[i - 1];
      final f = t1 == t0 ? 0.0 : (t - t0) / (t1 - t0);
      // Smoothed, so a muscle swells rather than changing at a corner.
      final s = f * f * (3 - 2 * f);
      return (u0 + (u1 - u0) * s, v0 + (v1 - v0) * s);
    }
  }
  return (profile.last.$2, profile.last.$3);
}

/// A limb from [a] to [b] whose thickness follows [profile], rounded off at
/// both ends so it meets its neighbours without a gap when a joint bends.
BodyPart _limb(
  Vec3 a,
  Vec3 b,
  Vec3 hint,
  Vec3 fallback,
  _Profile profile, {
  int rings = 9,
}) {
  final span = b - a;
  final dir = span.normalized;
  final u = _across(dir, hint, fallback);
  final v = dir.cross(u).normalized;
  final (u0, v0) = _radii(profile, 0);
  final (u1, v1) = _radii(profile, 1);
  return _part([
    _Ring(a - dir * (u0 * 0.95), u, v, u0 * 0.05, v0 * 0.05),
    _Ring(a - dir * (u0 * 0.8), u, v, u0 * 0.55, v0 * 0.55),
    _Ring(a - dir * (u0 * 0.45), u, v, u0 * 0.88, v0 * 0.88),
    for (var i = 0; i < rings; i++)
      () {
        final t = i / (rings - 1);
        final (ru, rv) = _radii(profile, t);
        return _Ring(a + span * t, u, v, ru, rv);
      }(),
    _Ring(b + dir * (u1 * 0.45), u, v, u1 * 0.88, v1 * 0.88),
    _Ring(b + dir * (u1 * 0.8), u, v, u1 * 0.55, v1 * 0.55),
    _Ring(b + dir * (u1 * 0.95), u, v, u1 * 0.05, v1 * 0.05),
  ]);
}

/// A rounded solid: [rAxis] along [axis], [ru] to the side, [rv] front to
/// back.
BodyPart _ellipsoid(
  Vec3 centre,
  Vec3 axis,
  Vec3 hint,
  Vec3 fallback,
  double rAxis,
  double ru,
  double rv, {
  int rings = 9,
}) {
  final dir = axis.normalized;
  final u = _across(dir, hint, fallback);
  final v = dir.cross(u).normalized;
  return _part([
    for (var i = 0; i < rings; i++)
      () {
        final latitude = -math.pi / 2 + math.pi * i / (rings - 1);
        final width = math.max(math.cos(latitude), 0.04);
        return _Ring(
          centre + dir * (rAxis * math.sin(latitude)),
          u,
          v,
          ru * width,
          rv * width,
        );
      }(),
  ]);
}

/// The whole body around a solved skeleton.
List<BodyPart> buildBody(Map<Joint, Vec3> j) {
  final pelvis = j[Joint.pelvis]!;
  final chest = j[Joint.chest]!;
  final spine = chest - pelvis;
  final up = spine.normalized;
  final shoulders =
      (j[Joint.leftShoulder]! - j[Joint.rightShoulder]!).normalized;
  final hips = (j[Joint.leftHip]! - j[Joint.rightHip]!).normalized;
  final front = shoulders.cross(up).normalized;

  // The trunk, from between the legs to the base of the neck: narrow at the
  // waist, widest across the chest.
  _Ring trunk(double s, double halfWidth, double halfDepth) {
    final side = Vec3.lerp(hips, shoulders, s.clamp(0.0, 1.0)).normalized;
    return _Ring(
      pelvis + spine * s,
      side,
      side.cross(up).normalized,
      halfWidth,
      halfDepth,
    );
  }

  final parts = <BodyPart>[
    _part([
      trunk(-0.21, 0.008, 0.008),
      trunk(-0.19, 0.075, 0.06),
      trunk(-0.13, 0.15, 0.098),
      trunk(-0.03, 0.186, 0.112),
      trunk(0.12, 0.166, 0.102),
      trunk(0.30, 0.134, 0.088),
      trunk(0.46, 0.138, 0.092),
      trunk(0.64, 0.160, 0.106),
      trunk(0.80, 0.184, 0.112),
      trunk(0.93, 0.190, 0.104),
      trunk(1.02, 0.150, 0.086),
      trunk(1.09, 0.078, 0.062),
      trunk(1.13, 0.008, 0.008),
    ]),
    // Neck and head.
    _limb(
      pelvis + spine * 1.06,
      j[Joint.head]! - up * 0.07,
      shoulders,
      front,
      const [(0, 0.052, 0.052), (1, 0.046, 0.048)],
      rings: 4,
    ),
    _ellipsoid(
      j[Joint.head]! + up * 0.012,
      up,
      shoulders,
      front,
      0.122,
      0.086,
      0.1,
      rings: 11,
    ),
  ];

  for (final (shoulder, elbow, wrist) in [
    (Joint.leftShoulder, Joint.leftElbow, Joint.leftWrist),
    (Joint.rightShoulder, Joint.rightElbow, Joint.rightWrist),
  ]) {
    final s = j[shoulder]!;
    final e = j[elbow]!;
    final w = j[wrist]!;
    final forearm = (w - e).normalized;
    parts
      // The shoulder muscle, then the upper arm, forearm and hand.
      ..add(_ellipsoid(s, up, shoulders, front, 0.07, 0.068, 0.07, rings: 7))
      ..add(
        _limb(s, e, front, shoulders, const [
          (0, 0.056, 0.058),
          (0.22, 0.06, 0.062),
          (0.6, 0.05, 0.052),
          (1, 0.041, 0.042),
        ]),
      )
      ..add(
        _limb(e, w, front, shoulders, const [
          (0, 0.042, 0.043),
          (0.24, 0.047, 0.046),
          (0.7, 0.035, 0.033),
          (1, 0.028, 0.026),
        ]),
      )
      ..add(
        _ellipsoid(
          w + forearm * 0.07,
          forearm,
          front,
          shoulders,
          0.075,
          0.036,
          0.02,
          rings: 7,
        ),
      );
  }

  for (final (hip, knee, ankle, toe) in [
    (Joint.leftHip, Joint.leftKnee, Joint.leftAnkle, Joint.leftToe),
    (Joint.rightHip, Joint.rightKnee, Joint.rightAnkle, Joint.rightToe),
  ]) {
    final h = j[hip]!;
    final k = j[knee]!;
    final a = j[ankle]!;
    final t = j[toe]!;
    final foot = (t - a).normalized;
    parts
      ..add(
        _limb(h, k, hips, front, const [
          (0, 0.092, 0.098),
          (0.16, 0.099, 0.104),
          (0.5, 0.084, 0.088),
          (0.86, 0.062, 0.064),
          (1, 0.058, 0.06),
        ]),
      )
      ..add(
        _limb(k, a, hips, front, const [
          (0, 0.057, 0.059),
          (0.24, 0.063, 0.068),
          (0.55, 0.05, 0.053),
          (0.88, 0.037, 0.038),
          (1, 0.036, 0.037),
        ]),
      )
      // The foot: from behind the heel to the toes, flatter towards the front.
      ..add(
        _limb(
          a - foot * 0.035 - Vec3.up * 0.012,
          t,
          foot.cross(Vec3.up),
          hips,
          const [
            (0, 0.04, 0.042),
            (0.35, 0.046, 0.036),
            (0.8, 0.044, 0.024),
            (1, 0.036, 0.016),
          ],
          rings: 6,
        ),
      );
  }
  return parts;
}
