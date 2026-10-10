import 'dart:math' as math;

/// The 3D body model behind every hologram in the app: a jointed mannequin
/// posed by a few clinical angles, then projected in perspective by the
/// painter.
///
/// World units are metres-ish: y is up, x is the figure's left (the viewer's
/// right when it faces you) and z points out of the screen towards the
/// viewer.
class Vec3 {
  const Vec3(this.x, this.y, this.z);

  static const zero = Vec3(0, 0, 0);
  static const right = Vec3(1, 0, 0);
  static const up = Vec3(0, 1, 0);
  static const down = Vec3(0, -1, 0);
  static const forward = Vec3(0, 0, 1);

  final double x;
  final double y;
  final double z;

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;
  Vec3 cross(Vec3 o) =>
      Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(dot(this));
  Vec3 get normalized {
    final l = length;
    return l == 0 ? this : this * (1 / l);
  }

  /// Rodrigues' rotation about the unit [axis] by [degrees].
  Vec3 rotate(Vec3 axis, double degrees) {
    if (degrees == 0) return this;
    final r = degrees * math.pi / 180;
    final c = math.cos(r);
    final s = math.sin(r);
    final k = axis.normalized;
    return this * c + k.cross(this) * s + k * (k.dot(this) * (1 - c));
  }

  static Vec3 lerp(Vec3 a, Vec3 b, double t) => a + (b - a) * t;
}

enum Joint {
  head,
  neck,
  chest,
  pelvis,
  leftShoulder,
  rightShoulder,
  leftElbow,
  rightElbow,
  leftWrist,
  rightWrist,
  leftHip,
  rightHip,
  leftKnee,
  rightKnee,
  leftAnkle,
  rightAnkle,
  leftToe,
  rightToe,
}

/// One arm or leg: flexion forwards, abduction out to the side, bend at the
/// elbow or knee, and (legs only) how far the knee collapses inwards.
class LimbPose {
  const LimbPose({
    this.flex = 0,
    this.abduct = 0,
    this.bend = 0,
    this.inward = 0,
  });

  final double flex;
  final double abduct;
  final double bend;

  /// Inward drift of the knee towards the midline, in world units.
  final double inward;

  LimbPose get withoutCollapse =>
      LimbPose(flex: flex, abduct: abduct, bend: bend);

  static LimbPose lerp(LimbPose a, LimbPose b, double t) => LimbPose(
    flex: a.flex + (b.flex - a.flex) * t,
    abduct: a.abduct + (b.abduct - a.abduct) * t,
    bend: a.bend + (b.bend - a.bend) * t,
    inward: a.inward + (b.inward - a.inward) * t,
  );
}

class BodyPose {
  const BodyPose({
    this.lean = 0,
    this.tilt = 0,
    this.pitch = 0,
    this.leftArm = const LimbPose(abduct: 7),
    this.rightArm = const LimbPose(abduct: 7),
    this.leftLeg = const LimbPose(abduct: 4),
    this.rightLeg = const LimbPose(abduct: 4),
  });

  /// Forward lean of the trunk, degrees.
  final double lean;

  /// Sideways lean of the trunk towards the figure's left (+x), degrees.
  final double tilt;

  /// Whole-body pitch face-down, for floor exercises such as the plank.
  final double pitch;
  final LimbPose leftArm;
  final LimbPose rightArm;
  final LimbPose leftLeg;
  final LimbPose rightLeg;

  BodyPose copyWith({
    double? lean,
    double? tilt,
    double? pitch,
    LimbPose? leftArm,
    LimbPose? rightArm,
    LimbPose? leftLeg,
    LimbPose? rightLeg,
  }) => BodyPose(
    lean: lean ?? this.lean,
    tilt: tilt ?? this.tilt,
    pitch: pitch ?? this.pitch,
    leftArm: leftArm ?? this.leftArm,
    rightArm: rightArm ?? this.rightArm,
    leftLeg: leftLeg ?? this.leftLeg,
    rightLeg: rightLeg ?? this.rightLeg,
  );

  static BodyPose lerp(BodyPose a, BodyPose b, double t) => BodyPose(
    lean: a.lean + (b.lean - a.lean) * t,
    tilt: a.tilt + (b.tilt - a.tilt) * t,
    pitch: a.pitch + (b.pitch - a.pitch) * t,
    leftArm: LimbPose.lerp(a.leftArm, b.leftArm, t),
    rightArm: LimbPose.lerp(a.rightArm, b.rightArm, t),
    leftLeg: LimbPose.lerp(a.leftLeg, b.leftLeg, t),
    rightLeg: LimbPose.lerp(a.rightLeg, b.rightLeg, t),
  );
}

// Proportions of an adult of about 1.75 m.
const _hipHalf = 0.10;
const _shoulderHalf = 0.19;
const _trunk = 0.50;
const _neck = 0.09;
const _headUp = 0.12;
const _thigh = 0.44;
const _shin = 0.43;
const _foot = 0.15;
const _upperArm = 0.29;
const _forearm = 0.27;

/// Solves the joint positions of [pose], standing on the floor (y = 0).
Map<Joint, Vec3> skeletonFor(BodyPose pose) {
  final j = <Joint, Vec3>{};
  const pelvis = Vec3.zero;
  final trunkDir = Vec3.up
      .rotate(Vec3.right, pose.lean)
      .rotate(Vec3.forward, -pose.tilt);
  final lateral = Vec3.right.rotate(Vec3.forward, -pose.tilt);
  final chest = pelvis + trunkDir * _trunk;
  j[Joint.pelvis] = pelvis;
  j[Joint.chest] = chest;
  j[Joint.neck] = chest + trunkDir * _neck;
  j[Joint.head] = chest + trunkDir * (_neck + _headUp);
  j[Joint.leftShoulder] = chest + lateral * _shoulderHalf;
  j[Joint.rightShoulder] = chest - lateral * _shoulderHalf;

  void leg(
    double side,
    LimbPose limb,
    Joint hipJ,
    Joint kneeJ,
    Joint ankleJ,
    Joint toeJ,
  ) {
    final hip = pelvis + Vec3.right * (_hipHalf * side);
    final thighDir = Vec3.down
        .rotate(Vec3.right, -limb.flex)
        .rotate(Vec3.forward, side * limb.abduct);
    final axis = Vec3.right.rotate(Vec3.forward, side * limb.abduct);
    final knee = hip + thighDir * _thigh;
    final shinDir = thighDir.rotate(axis, limb.bend);
    final ankle = knee + shinDir * _shin;
    // The foot sits at right angles to the shin, but stays flat on the
    // floor unless the shin is far behind the body (the back foot of a
    // lunge, up on its toes).
    final shinAngle = (limb.flex - limb.bend) * math.pi / 180;
    final footDir = Vec3(
      0,
      math.min(math.sin(shinAngle), 0.0),
      math.cos(shinAngle).abs(),
    ).normalized.rotate(Vec3.up, side * 12);
    j[hipJ] = hip;
    j[kneeJ] = knee + Vec3.right * (-side * limb.inward);
    j[ankleJ] = ankle;
    j[toeJ] = ankle + footDir * _foot + Vec3.down * 0.03;
  }

  void arm(
    double side,
    LimbPose limb,
    Joint shoulderJ,
    Joint elbowJ,
    Joint wristJ,
  ) {
    final shoulder = j[shoulderJ]!;
    final upperDir = Vec3.down
        .rotate(Vec3.right, -limb.flex)
        .rotate(Vec3.forward, side * limb.abduct);
    final axis = Vec3.right.rotate(Vec3.forward, side * limb.abduct);
    final elbow = shoulder + upperDir * _upperArm;
    final forearmDir = upperDir.rotate(axis, -limb.bend);
    j[elbowJ] = elbow;
    j[wristJ] = elbow + forearmDir * _forearm;
  }

  leg(
    1,
    pose.leftLeg,
    Joint.leftHip,
    Joint.leftKnee,
    Joint.leftAnkle,
    Joint.leftToe,
  );
  leg(
    -1,
    pose.rightLeg,
    Joint.rightHip,
    Joint.rightKnee,
    Joint.rightAnkle,
    Joint.rightToe,
  );
  arm(1, pose.leftArm, Joint.leftShoulder, Joint.leftElbow, Joint.leftWrist);
  arm(
    -1,
    pose.rightArm,
    Joint.rightShoulder,
    Joint.rightElbow,
    Joint.rightWrist,
  );

  if (pose.pitch != 0) {
    for (final key in j.keys.toList()) {
      j[key] = j[key]!.rotate(Vec3.right, pose.pitch);
    }
  }

  // Stand it on the floor: whatever is lowest touches y = 0.
  var floor = double.infinity;
  for (final joint in const [
    Joint.leftAnkle,
    Joint.rightAnkle,
    Joint.leftToe,
    Joint.rightToe,
    Joint.leftKnee,
    Joint.rightKnee,
    Joint.leftWrist,
    Joint.rightWrist,
  ]) {
    floor = math.min(floor, j[joint]!.y);
  }
  final lift = Vec3(0, -floor + 0.05, 0);
  return {for (final entry in j.entries) entry.key: entry.value + lift};
}

/// The exercises the app has motion for.
enum HoloExercise {
  stand,
  squat,
  lunge,
  pushUp,
  armAbduction,
  legAbduction;

  static HoloExercise fromSlug(String? slug) => switch (slug) {
    'squats' => squat,
    'leg-lunge' => lunge,
    'push-ups' => pushUp,
    'arm-abduction' => armAbduction,
    'leg-abduction' => legAbduction,
    _ => stand,
  };

  /// From an exercise's slug, falling back to its name for records that
  /// carry none.
  static HoloExercise of(String slug, String name) {
    final bySlug = fromSlug(slug);
    return bySlug == stand ? fromName(name) : bySlug;
  }

  /// For records that carry only a display name, such as "Leg Lunge".
  static HoloExercise fromName(String name) {
    final n = name.toLowerCase();
    if (n.contains('squat')) return squat;
    if (n.contains('lunge')) return lunge;
    if (n.contains('push')) return pushUp;
    if (n.contains('arm') && n.contains('abduct')) return armAbduction;
    if (n.contains('leg') && n.contains('abduct')) return legAbduction;
    return stand;
  }
}

/// What can go wrong in a repetition, named after the server's check keys.
enum HoloFault {
  none,
  kneeValgus,
  trunkLean,
  kneeForward,
  hipSag,
  shallowDepth,
  elbowBend,
  kneeBend;

  static HoloFault fromCheck(String? key) => switch (key) {
    'knee_valgus' => kneeValgus,
    'trunk_lean' => trunkLean,
    'knee_forward' => kneeForward,
    'hip_sag' => hipSag,
    'depth' => shallowDepth,
    'elbow_bend' => elbowBend,
    'knee_bend' => kneeBend,
    _ => none,
  };

  /// A short clinical name, for headings such as "KNEE ALIGNMENT".
  String get title => switch (this) {
    none => 'Good form',
    kneeValgus => 'Knee alignment',
    trunkLean => 'Trunk posture',
    kneeForward => 'Knee position',
    hipSag => 'Body line',
    shallowDepth => 'Depth',
    elbowBend => 'Elbow straightness',
    kneeBend => 'Leg straightness',
  };
}

/// A straight reference line drawn beside the figure: the "ideal" path.
class HoloGuide {
  const HoloGuide.between(this.from, this.to) : vertical = false;

  /// A plumb line rising from [from].
  const HoloGuide.plumb(this.from) : to = null, vertical = true;

  final Joint from;
  final Joint? to;
  final bool vertical;
}

/// Everything needed to draw one exercise, with or without a fault.
class HoloScene {
  const HoloScene({
    required this.rest,
    required this.peak,
    required this.yaw,
    this.highlights = const [],
    this.guides = const [],
    this.span = 1.0,
  });

  final BodyPose rest;
  final BodyPose peak;

  /// The angle it is best seen from, degrees around the vertical.
  final double yaw;
  final List<Joint> highlights;
  final List<HoloGuide> guides;

  /// Rough width of the movement, for fitting it to the frame.
  final double span;

  static HoloScene of(
    HoloExercise exercise, [
    HoloFault fault = HoloFault.none,
  ]) {
    final base = _correct[exercise]!;
    final variant = _faults[(exercise, fault)];
    if (variant == null) {
      return HoloScene(
        rest: base.rest,
        peak: base.peak,
        yaw: base.yaw,
        span: base.span,
        highlights: _defaultFocus(exercise, fault),
        guides: _defaultGuides(exercise, fault),
      );
    }
    return variant;
  }

  /// The correct version of the scene a fault belongs to: same view, same
  /// guides, so the two can be compared side by side.
  static HoloScene correctFor(HoloExercise exercise, HoloFault fault) {
    final faulty = of(exercise, fault);
    final base = _correct[exercise]!;
    // A knee that caves in is shown against the same stance with the knees
    // tracking over the toes.
    final peak = fault == HoloFault.kneeValgus
        ? faulty.peak.copyWith(
            leftLeg: faulty.peak.leftLeg.withoutCollapse,
            rightLeg: faulty.peak.rightLeg.withoutCollapse,
          )
        : base.peak;
    return HoloScene(
      rest: base.rest,
      peak: peak,
      yaw: faulty.yaw,
      span: base.span,
      highlights: faulty.highlights,
      guides: faulty.guides,
    );
  }
}

List<Joint> _defaultFocus(HoloExercise exercise, HoloFault fault) =>
    switch (fault) {
      HoloFault.kneeValgus ||
      HoloFault.kneeForward ||
      HoloFault.kneeBend => [Joint.leftKnee],
      HoloFault.trunkLean => [Joint.chest],
      HoloFault.hipSag => [Joint.pelvis],
      HoloFault.shallowDepth =>
        exercise == HoloExercise.pushUp
            ? [Joint.leftElbow, Joint.rightElbow]
            : [Joint.pelvis],
      HoloFault.elbowBend => [Joint.leftElbow, Joint.rightElbow],
      HoloFault.none => const [],
    };

List<HoloGuide> _defaultGuides(HoloExercise exercise, HoloFault fault) =>
    switch (fault) {
      HoloFault.trunkLean => const [HoloGuide.plumb(Joint.pelvis)],
      _ => const [],
    };

const _standing = BodyPose();

const _squatPeak = BodyPose(
  lean: 30,
  leftArm: LimbPose(flex: 82, abduct: 8),
  rightArm: LimbPose(flex: 82, abduct: 8),
  leftLeg: LimbPose(flex: 92, abduct: 9, bend: 104),
  rightLeg: LimbPose(flex: 92, abduct: 9, bend: 104),
);

const _lungePeak = BodyPose(
  lean: 4,
  leftArm: LimbPose(abduct: 14, bend: 10),
  rightArm: LimbPose(abduct: 14, bend: 10),
  leftLeg: LimbPose(flex: 84, abduct: 3, bend: 86),
  rightLeg: LimbPose(flex: -10, abduct: 3, bend: 100),
);

// In a plank the arms stay vertical under the shoulders: their flexion plus
// the elbow bend always equals the body's pitch.
const _plankUp = BodyPose(
  pitch: 66,
  leftArm: LimbPose(flex: 66, abduct: 8),
  rightArm: LimbPose(flex: 66, abduct: 8),
  leftLeg: LimbPose(abduct: 3),
  rightLeg: LimbPose(abduct: 3),
);

const _plankDown = BodyPose(
  pitch: 73,
  leftArm: LimbPose(flex: 20, abduct: 16, bend: 53),
  rightArm: LimbPose(flex: 20, abduct: 16, bend: 53),
  leftLeg: LimbPose(abduct: 3),
  rightLeg: LimbPose(abduct: 3),
);

const _armsRaised = BodyPose(
  leftArm: LimbPose(abduct: 90),
  rightArm: LimbPose(abduct: 90),
);

const _legOut = BodyPose(
  leftArm: LimbPose(abduct: 24),
  rightArm: LimbPose(abduct: 24),
  leftLeg: LimbPose(abduct: 34),
  rightLeg: LimbPose(abduct: 2),
);

const _correct = <HoloExercise, HoloScene>{
  HoloExercise.stand: HoloScene(rest: _standing, peak: _standing, yaw: 22),
  HoloExercise.squat: HoloScene(rest: _standing, peak: _squatPeak, yaw: 38),
  HoloExercise.lunge: HoloScene(
    rest: _standing,
    peak: _lungePeak,
    yaw: 62,
    span: 1.2,
  ),
  HoloExercise.pushUp: HoloScene(
    rest: _plankUp,
    peak: _plankDown,
    yaw: 74,
    span: 2.0,
  ),
  HoloExercise.armAbduction: HoloScene(
    rest: _standing,
    peak: _armsRaised,
    yaw: 12,
    span: 1.6,
  ),
  HoloExercise.legAbduction: HoloScene(
    rest: _standing,
    peak: _legOut,
    yaw: 12,
    span: 1.2,
  ),
};

final _faults = <(HoloExercise, HoloFault), HoloScene>{
  (HoloExercise.squat, HoloFault.kneeValgus): HoloScene(
    rest: _standing,
    peak: _squatPeak.copyWith(
      leftLeg: const LimbPose(flex: 92, abduct: 15, bend: 104, inward: 0.1),
      rightLeg: const LimbPose(flex: 92, abduct: 15, bend: 104, inward: 0.1),
    ),
    yaw: 18,
    highlights: const [Joint.leftKnee, Joint.rightKnee],
    guides: const [
      HoloGuide.between(Joint.leftHip, Joint.leftAnkle),
      HoloGuide.between(Joint.rightHip, Joint.rightAnkle),
    ],
  ),
  (HoloExercise.squat, HoloFault.trunkLean): HoloScene(
    rest: _standing,
    peak: _squatPeak.copyWith(lean: 64),
    yaw: 70,
    highlights: const [Joint.chest],
    guides: const [HoloGuide.plumb(Joint.pelvis)],
  ),
  (HoloExercise.squat, HoloFault.shallowDepth): HoloScene(
    rest: _standing,
    peak: _squatPeak.copyWith(
      lean: 14,
      leftLeg: const LimbPose(flex: 46, abduct: 9, bend: 52),
      rightLeg: const LimbPose(flex: 46, abduct: 9, bend: 52),
    ),
    yaw: 70,
    highlights: const [Joint.pelvis],
  ),
  (HoloExercise.lunge, HoloFault.kneeForward): HoloScene(
    rest: _standing,
    peak: _lungePeak.copyWith(
      leftLeg: const LimbPose(flex: 66, abduct: 3, bend: 112),
    ),
    yaw: 80,
    span: 1.2,
    highlights: const [Joint.leftKnee],
    guides: const [HoloGuide.plumb(Joint.leftToe)],
  ),
  (HoloExercise.lunge, HoloFault.kneeValgus): HoloScene(
    rest: _standing,
    peak: _lungePeak.copyWith(
      leftLeg: const LimbPose(flex: 84, abduct: 3, bend: 86, inward: 0.12),
    ),
    yaw: 18,
    span: 1.2,
    highlights: const [Joint.leftKnee],
    guides: const [HoloGuide.between(Joint.leftHip, Joint.leftAnkle)],
  ),
  (HoloExercise.lunge, HoloFault.trunkLean): HoloScene(
    rest: _standing,
    peak: _lungePeak.copyWith(lean: 38),
    yaw: 80,
    span: 1.2,
    highlights: const [Joint.chest],
    guides: const [HoloGuide.plumb(Joint.pelvis)],
  ),
  (HoloExercise.pushUp, HoloFault.hipSag): HoloScene(
    rest: _plankUp.copyWith(
      leftLeg: const LimbPose(flex: -14, abduct: 3),
      rightLeg: const LimbPose(flex: -14, abduct: 3),
    ),
    peak: _plankDown.copyWith(
      leftLeg: const LimbPose(flex: -24, abduct: 3),
      rightLeg: const LimbPose(flex: -24, abduct: 3),
    ),
    yaw: 82,
    span: 2.0,
    highlights: const [Joint.pelvis],
    guides: const [HoloGuide.between(Joint.leftShoulder, Joint.leftAnkle)],
  ),
  (HoloExercise.pushUp, HoloFault.shallowDepth): HoloScene(
    rest: _plankUp,
    peak: _plankDown.copyWith(
      pitch: 68,
      leftArm: const LimbPose(flex: 52, abduct: 10, bend: 16),
      rightArm: const LimbPose(flex: 52, abduct: 10, bend: 16),
    ),
    yaw: 82,
    span: 2.0,
    highlights: const [Joint.leftElbow, Joint.rightElbow],
  ),
  (HoloExercise.armAbduction, HoloFault.trunkLean): HoloScene(
    rest: _standing,
    peak: _armsRaised.copyWith(tilt: -17),
    yaw: 6,
    span: 1.6,
    highlights: const [Joint.chest],
    guides: const [HoloGuide.plumb(Joint.pelvis)],
  ),
  (HoloExercise.armAbduction, HoloFault.elbowBend): HoloScene(
    rest: _standing,
    peak: _armsRaised.copyWith(
      leftArm: const LimbPose(abduct: 86, bend: 52),
      rightArm: const LimbPose(abduct: 86, bend: 52),
    ),
    yaw: 14,
    span: 1.6,
    highlights: const [Joint.leftElbow, Joint.rightElbow],
    guides: const [
      HoloGuide.between(Joint.leftShoulder, Joint.leftWrist),
      HoloGuide.between(Joint.rightShoulder, Joint.rightWrist),
    ],
  ),
  (HoloExercise.legAbduction, HoloFault.trunkLean): HoloScene(
    rest: _standing,
    peak: _legOut.copyWith(tilt: -18),
    yaw: 6,
    span: 1.2,
    highlights: const [Joint.chest],
    guides: const [HoloGuide.plumb(Joint.pelvis)],
  ),
  (HoloExercise.legAbduction, HoloFault.kneeBend): HoloScene(
    rest: _standing,
    peak: _legOut.copyWith(
      leftLeg: const LimbPose(flex: 16, abduct: 30, bend: 44),
    ),
    yaw: 16,
    span: 1.2,
    highlights: const [Joint.leftKnee],
    guides: const [HoloGuide.between(Joint.leftHip, Joint.leftAnkle)],
  ),
};
