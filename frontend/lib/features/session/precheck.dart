import 'dart:math' as math;

import '../exercises/exercise_models.dart';
import 'pose/pose_models.dart';
import 'repetitions.dart';
import 'session_records.dart';

/// What the camera has to show before a session with one exercise can start.
/// Comes from the API, which judges the result against the same numbers.
class PrecheckRequirements {
  const PrecheckRequirements({
    required this.itemId,
    required this.exercise,
    required this.sets,
    required this.reps,
    required this.restSeconds,
    required this.difficulty,
    required this.requiredLandmarks,
    required this.minVisibility,
    required this.minBrightness,
    required this.holdMs,
    this.cameraView = CameraView.front,
    this.frontMinRatio = 0.55,
    this.sideMaxRatio = 0.35,
  });

  factory PrecheckRequirements.fromJson(Map<String, dynamic> json) =>
      PrecheckRequirements(
        itemId: json['item_id'] as String,
        exercise: ExerciseBrief.fromJson(
          json['exercise'] as Map<String, dynamic>,
        ),
        sets: json['sets'] as int,
        reps: json['reps'] as int,
        restSeconds: json['rest_seconds'] as int,
        difficulty: Difficulty.fromApi(json['difficulty'] as String),
        requiredLandmarks: [
          for (final name in json['required_landmarks'] as List<dynamic>)
            name as String,
        ],
        minVisibility: (json['min_visibility'] as num).toDouble(),
        minBrightness: (json['min_brightness'] as num).toDouble(),
        holdMs: json['hold_ms'] as int,
        cameraView: CameraView.fromApi(json['camera_view'] as String?),
        frontMinRatio: (json['front_min_ratio'] as num?)?.toDouble() ?? 0.55,
        sideMaxRatio: (json['side_max_ratio'] as num?)?.toDouble() ?? 0.35,
      );

  final String itemId;
  final ExerciseBrief exercise;
  final int sets;
  final int reps;
  final int restSeconds;
  final Difficulty difficulty;
  final List<String> requiredLandmarks;
  final double minVisibility;
  final double minBrightness;
  final int holdMs;

  /// Which way the patient faces the camera for this exercise.
  final CameraView cameraView;

  /// Shoulder width against trunk height: at least this facing the camera,
  /// at most [sideMaxRatio] side-on. Set by the API from REHAB24-6's
  /// labelled views.
  final double frontMinRatio;
  final double sideMaxRatio;
}

/// Which way the patient faces the camera. Some checks only measure what
/// they claim from one side: knee alignment and a sideways lean from the
/// front; a forward lean, hip sag and depth from the side.
enum CameraView {
  front,
  side;

  static CameraView fromApi(String? value) => value == 'side' ? side : front;
}

/// Landmarks at least this visible count for telling which way someone
/// faces. Lower than for measuring: from the side the far shoulder is half
/// hidden, and only its rough position matters here.
const facingMinVisibility = 0.3;

/// Shoulder width against trunk height in one frame (x scaled by the
/// picture's aspect ratio): about 0.6 to 0.8 facing the camera, under 0.3
/// side-on. Null when the shoulders and hips are not all in view.
double? shoulderRatio(PoseFrame frame, double aspectRatio) {
  final ls = frame.landmarks['left_shoulder'];
  final rs = frame.landmarks['right_shoulder'];
  final lh = frame.landmarks['left_hip'];
  final rh = frame.landmarks['right_hip'];
  if (ls == null || rs == null || lh == null || rh == null) return null;
  if ([ls, rs, lh, rh].any((p) => p.visibility < facingMinVisibility)) {
    return null;
  }
  final width = (ls.x - rs.x).abs() * aspectRatio;
  final dx = ((ls.x + rs.x) - (lh.x + rh.x)) / 2 * aspectRatio;
  final dy = ((ls.y + rs.y) - (lh.y + rh.y)) / 2;
  final trunk = math.sqrt(dx * dx + dy * dy);
  return trunk == 0 ? null : width / trunk;
}

String? _otherSide(String name) => name.startsWith('left_')
    ? 'right_${name.substring(5)}'
    : name.startsWith('right_')
    ? 'left_${name.substring(6)}'
    : null;

/// One camera frame judged against the requirements.
class SetupReading {
  const SetupReading({
    required this.lightingOk,
    required this.missing,
    required this.personSeen,
    this.facingOk = true,
    this.shoulderRatio,
    this.guidance,
  });

  final bool lightingOk;

  /// Required landmarks that are not clearly in view.
  final List<String> missing;

  /// False when the camera found nobody at all.
  final bool personSeen;

  /// The patient faces the camera the way the exercise needs.
  final bool facingOk;

  /// Shoulder width against trunk height in this frame, if measurable.
  final double? shoulderRatio;

  /// What the patient should do next; null when the setup is good.
  final String? guidance;

  bool get bodyOk => personSeen && missing.isEmpty;
  bool get ok => lightingOk && bodyOk && facingOk;
}

bool _all(Iterable<String> names, bool Function(String) test) =>
    names.isNotEmpty && names.every(test);

/// Judges one frame and says, specifically, what to change.
SetupReading judgeSetup(
  PoseFrame frame,
  PrecheckRequirements requirements, {
  double aspectRatio = 4 / 3,
}) {
  final lightingOk = frame.brightness >= requirements.minBrightness;
  final personSeen = frame.landmarks.isNotEmpty;
  final side = requirements.cameraView == CameraView.side;
  // Side-on, the far half of the body is hidden: a joint counts when either
  // side of it is clearly in view, which is all the measurements need.
  bool seen(String name) {
    if (frame.visibilityOf(name) >= requirements.minVisibility) return true;
    final other = side ? _otherSide(name) : null;
    return other != null &&
        frame.visibilityOf(other) >= requirements.minVisibility;
  }

  final missing = [
    for (final name in requirements.requiredLandmarks)
      if (!seen(name)) name,
  ];
  final ratio = shoulderRatio(frame, aspectRatio);
  final facingOk =
      ratio != null &&
      (side
          ? ratio <= requirements.sideMaxRatio
          : ratio >= requirements.frontMinRatio);

  String? guidance;
  if (!lightingOk) {
    // Said first: in poor light the body cannot be judged at all.
    guidance =
        'It is too dark to see you clearly. Turn on a light or face a window.';
  } else if (!personSeen ||
      missing.length == requirements.requiredLandmarks.length) {
    guidance = 'Stand in front of the camera so it can see you.';
  } else if (missing.isNotEmpty) {
    bool part(String word) => missing.any((name) => name.contains(word));
    final legs = part('knee') || part('ankle');
    final arms = part('elbow') || part('wrist');
    if (_all(missing, (name) => name.startsWith('left_'))) {
      guidance = 'Move a little to your right so your whole body is in view.';
    } else if (_all(missing, (name) => name.startsWith('right_'))) {
      guidance = 'Move a little to your left so your whole body is in view.';
    } else if (legs && !part('shoulder')) {
      guidance = part('knee')
          ? 'Step back so your legs are visible.'
          : 'Step back so your feet are visible.';
    } else if (part('shoulder') && !legs) {
      guidance =
          'Step back or tilt the camera up so your shoulders are visible.';
    } else if (arms && !legs && !part('shoulder') && !part('hip')) {
      guidance = 'Step back so your arms stay in view.';
    } else {
      guidance = 'Step back until your whole body fits in the picture.';
    }
  } else if (!facingOk) {
    guidance = side
        ? 'Turn sideways so the camera sees your side.'
        : 'Turn to face the camera.';
  }
  return SetupReading(
    lightingOk: lightingOk,
    missing: missing,
    personSeen: personSeen,
    facingOk: facingOk,
    shoulderRatio: ratio,
    guidance: guidance,
  );
}

/// Follows the camera until the setup has stayed good for long enough, and
/// keeps the weakest values seen during that time as the evidence to submit.
class PrecheckTracker {
  PrecheckTracker(this.requirements, {this.aspectRatio = 4 / 3});

  /// Width over height of the camera picture.
  final double aspectRatio;

  final PrecheckRequirements requirements;

  double? _goodSince;
  double _heldMs = 0;
  double _lowestBrightness = 1;
  final _lowestVisibility = <String, double>{};

  /// The shoulder ratio furthest from what the exercise needs during the
  /// hold: the lowest facing the camera, the highest side-on.
  double? _worstRatio;
  SetupReading? reading;

  /// How far through the hold the patient is, 0 to 1.
  double get progress => (_heldMs / requirements.holdMs).clamp(0, 1).toDouble();

  bool get ready => _heldMs >= requirements.holdMs;

  /// Call when the evidence was refused or a new attempt begins.
  void reset() {
    _goodSince = null;
    _heldMs = 0;
    _lowestBrightness = 1;
    _lowestVisibility.clear();
    _worstRatio = null;
  }

  SetupReading add(PoseFrame frame) {
    final judged = judgeSetup(frame, requirements, aspectRatio: aspectRatio);
    reading = judged;
    if (!judged.ok) {
      // Moving out of view or losing the light starts the hold again.
      reset();
      return judged;
    }
    _goodSince ??= frame.timeMs;
    _heldMs = frame.timeMs - _goodSince!;
    if (frame.brightness < _lowestBrightness) {
      _lowestBrightness = frame.brightness;
    }
    for (final name in requirements.requiredLandmarks) {
      final seen = frame.visibilityOf(name);
      final lowest = _lowestVisibility[name];
      if (lowest == null || seen < lowest) _lowestVisibility[name] = seen;
    }
    final ratio = judged.shoulderRatio;
    final worst = _worstRatio;
    if (ratio != null) {
      final side = requirements.cameraView == CameraView.side;
      if (worst == null || (side ? ratio > worst : ratio < worst)) {
        _worstRatio = ratio;
      }
    }
    return judged;
  }

  /// What is sent to the API to start the session. It carries measurements
  /// only: the server decides whether they pass.
  Map<String, dynamic> evidence() => {
    'brightness': double.parse(_lowestBrightness.toStringAsFixed(4)),
    'held_ms': _heldMs.round(),
    'visibility': {
      for (final entry in _lowestVisibility.entries)
        entry.key: double.parse(entry.value.toStringAsFixed(4)),
    },
    if (_worstRatio != null)
      'shoulder_ratio': double.parse(_worstRatio!.toStringAsFixed(4)),
  };
}

/// A session the server has started.
class ExerciseSession {
  const ExerciseSession({
    required this.id,
    required this.status,
    required this.startedAt,
    this.endedAt,
    this.checks = const [],
    this.totals = const SessionTotals(),
    this.pause,
    this.series,
    this.summary,
  });

  factory ExerciseSession.fromJson(Map<String, dynamic> json) =>
      ExerciseSession(
        id: json['id'] as String,
        status: json['status'] as String,
        startedAt: DateTime.parse(json['started_at'] as String),
        endedAt: DateTime.tryParse(json['ended_at'] as String? ?? ''),
        checks: [
          for (final check in json['checks'] as List<dynamic>? ?? const [])
            SessionCheck.fromJson(check as Map<String, dynamic>),
        ],
        totals: SessionTotals.fromJson(json['totals'] as Map<String, dynamic>?),
        pause: SessionPause.fromJson(json['pause'] as Map<String, dynamic>?),
        series: SeriesSpec.fromJson(json['series'] as Map<String, dynamic>?),
        summary: SessionSummary.fromJson(
          json['summary'] as Map<String, dynamic>?,
        ),
      );

  final String id;

  /// active | paused | completed | abandoned
  final String status;
  final DateTime startedAt;
  final DateTime? endedAt;

  /// The thresholds this session is judged against: its own copy.
  final List<SessionCheck> checks;
  final SessionTotals totals;

  /// Set while the session is paused on a RED repetition.
  final SessionPause? pause;

  /// Set while a trained model is to score this session: what to send
  /// with every repetition.
  final SeriesSpec? series;

  /// What the session came to; set once it has ended.
  final SessionSummary? summary;

  bool get isPaused => status == 'paused';
}
