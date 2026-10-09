import '../exercises/exercise_models.dart';
import 'pose/pose_models.dart';

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
}

/// One camera frame judged against the requirements.
class SetupReading {
  const SetupReading({
    required this.lightingOk,
    required this.missing,
    required this.personSeen,
    this.guidance,
  });

  final bool lightingOk;

  /// Required landmarks that are not clearly in view.
  final List<String> missing;

  /// False when the camera found nobody at all.
  final bool personSeen;

  /// What the patient should do next; null when the setup is good.
  final String? guidance;

  bool get bodyOk => personSeen && missing.isEmpty;
  bool get ok => lightingOk && bodyOk;
}

bool _all(Iterable<String> names, bool Function(String) test) =>
    names.isNotEmpty && names.every(test);

/// Judges one frame and says, specifically, what to change.
SetupReading judgeSetup(PoseFrame frame, PrecheckRequirements requirements) {
  final lightingOk = frame.brightness >= requirements.minBrightness;
  final personSeen = frame.landmarks.isNotEmpty;
  final missing = [
    for (final name in requirements.requiredLandmarks)
      if (frame.visibilityOf(name) < requirements.minVisibility) name,
  ];

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
  }
  return SetupReading(
    lightingOk: lightingOk,
    missing: missing,
    personSeen: personSeen,
    guidance: guidance,
  );
}

/// Follows the camera until the setup has stayed good for long enough, and
/// keeps the weakest values seen during that time as the evidence to submit.
class PrecheckTracker {
  PrecheckTracker(this.requirements);

  final PrecheckRequirements requirements;

  double? _goodSince;
  double _heldMs = 0;
  double _lowestBrightness = 1;
  final _lowestVisibility = <String, double>{};
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
  }

  SetupReading add(PoseFrame frame) {
    final judged = judgeSetup(frame, requirements);
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
  };
}

/// A session the server has started.
class ExerciseSession {
  const ExerciseSession({
    required this.id,
    required this.status,
    required this.startedAt,
    this.endedAt,
  });

  factory ExerciseSession.fromJson(Map<String, dynamic> json) =>
      ExerciseSession(
        id: json['id'] as String,
        status: json['status'] as String,
        startedAt: DateTime.parse(json['started_at'] as String),
        endedAt: DateTime.tryParse(json['ended_at'] as String? ?? ''),
      );

  final String id;

  /// active | completed | abandoned
  final String status;
  final DateTime startedAt;
  final DateTime? endedAt;
}
