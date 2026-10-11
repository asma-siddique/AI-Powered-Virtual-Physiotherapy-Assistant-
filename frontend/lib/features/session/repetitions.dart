import 'dart:math';

final _random = Random.secure();

/// A key the app makes once for each repetition. Sending a repetition again
/// with the same key (after a lost reply) makes the server answer with the one
/// it already stored, so a retry can never count a repetition twice.
String newClientKey() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  // Version 4, variant 1, so the key is a well-formed random UUID.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = [
    for (final byte in bytes) byte.toRadixString(16).padLeft(2, '0'),
  ].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// How serious the feedback for a repetition is, from least to most. The
/// server decides this from what was measured and the thresholds the session
/// started with; the app never decides it.
enum FeedbackTier {
  ok,
  info,
  amber,
  red;

  static FeedbackTier fromApi(String? value) => switch (value) {
    'info' => info,
    'amber' => amber,
    'red' => red,
    _ => ok,
  };
}

/// One thing the session watches, with the thresholds this session is judged
/// against: its own copy, taken when it started.
class SessionCheck {
  const SessionCheck({
    required this.key,
    required this.label,
    required this.unit,
    required this.info,
    required this.amber,
    this.red,
    required this.message,
  });

  factory SessionCheck.fromJson(Map<String, dynamic> json) => SessionCheck(
    key: json['key'] as String,
    label: json['label'] as String,
    unit: json['unit'] as String? ?? 'degrees',
    info: (json['info'] as num).toDouble(),
    amber: (json['amber'] as num).toDouble(),
    red: (json['red'] as num?)?.toDouble(),
    message: json['corrective_message'] as String,
  );

  final String key;
  final String label;
  final String unit;
  final double info;
  final double amber;

  /// Null for a check that is never a safety matter.
  final double? red;
  final String message;
}

/// How many repetitions a session holds, in all and by tier.
class SessionTotals {
  const SessionTotals({
    this.repetitions = 0,
    this.ok = 0,
    this.info = 0,
    this.amber = 0,
    this.red = 0,
  });

  factory SessionTotals.fromJson(Map<String, dynamic>? json) => SessionTotals(
    repetitions: json?['repetitions'] as int? ?? 0,
    ok: json?['ok'] as int? ?? 0,
    info: json?['info'] as int? ?? 0,
    amber: json?['amber'] as int? ?? 0,
    red: json?['red'] as int? ?? 0,
  );

  final int repetitions;
  final int ok;
  final int info;
  final int amber;
  final int red;
}

/// Why a session is paused: the RED repetition whose corrective message the
/// patient has to acknowledge before carrying on.
class SessionPause {
  const SessionPause({
    required this.repetitionId,
    required this.check,
    required this.message,
  });

  static SessionPause? fromJson(Map<String, dynamic>? json) => json == null
      ? null
      : SessionPause(
          repetitionId: json['repetition_id'] as String,
          check: json['check'] as String,
          message: json['message'] as String,
        );

  final String repetitionId;
  final String check;
  final String message;
}

/// What one check found in a repetition, at INFO or above.
class RepetitionFeedback {
  const RepetitionFeedback({
    required this.check,
    required this.label,
    required this.tier,
    required this.value,
    required this.message,
  });

  factory RepetitionFeedback.fromJson(Map<String, dynamic> json) =>
      RepetitionFeedback(
        check: json['check'] as String,
        label: json['label'] as String,
        tier: FeedbackTier.fromApi(json['tier'] as String?),
        value: (json['value'] as num).toDouble(),
        message: json['message'] as String,
      );

  final String check;
  final String label;
  final FeedbackTier tier;
  final double value;
  final String message;
}

/// One repetition the app has counted and is about to store.
///
/// It carries what was measured, never a verdict: the server classifies the
/// repetition against the thresholds the session started with.
class RepetitionDraft {
  RepetitionDraft({
    required this.setNumber,
    required this.repNumber,
    required this.startedMs,
    required this.endedMs,
    Map<String, double?> measures = const {},
    String? clientKey,
  }) : measures = Map.unmodifiable(measures),
       clientKey = clientKey ?? newClientKey() {
    if (setNumber < 1 || repNumber < 1) {
      throw ArgumentError('Sets and repetitions are counted from 1.');
    }
    if (startedMs < 0 || endedMs < startedMs) {
      throw ArgumentError('A repetition cannot end before it starts.');
    }
    for (final entry in measures.entries) {
      if (entry.value != null && !entry.value!.isFinite) {
        throw ArgumentError('The measure "${entry.key}" is not a number.');
      }
    }
  }

  final String clientKey;

  /// Which set of the prescription this repetition belongs to, from 1.
  final int setNumber;

  /// Its place within that set, from 1.
  final int repNumber;

  /// When the movement began and ended, in milliseconds since the session
  /// started on this device.
  final int startedMs;
  final int endedMs;

  /// For each of the session's checks, by its key, the worst value seen
  /// during the repetition in that check's own unit; null when the body parts
  /// it needs were not clearly in view, so nothing is guessed.
  final Map<String, double?> measures;

  Map<String, dynamic> toJson() => {
    'client_key': clientKey,
    'set_number': setNumber,
    'rep_number': repNumber,
    'started_ms': startedMs,
    'ended_ms': endedMs,
    'measures': {
      for (final entry in measures.entries)
        entry.key: entry.value == null
            ? null
            : double.parse(entry.value!.toStringAsFixed(2)),
    },
  };
}

/// A repetition the server has stored, with how it classified it. Feedback
/// shown to the patient comes from here and nowhere else.
class RecordedRepetition {
  const RecordedRepetition({
    required this.id,
    required this.setNumber,
    required this.repNumber,
    required this.startedMs,
    required this.endedMs,
    this.tier = FeedbackTier.ok,
    this.feedback = const [],
    this.unmeasured = const [],
    this.sessionStatus = 'active',
    this.pause,
  });

  factory RecordedRepetition.fromJson(Map<String, dynamic> json) =>
      RecordedRepetition(
        id: json['id'] as String,
        setNumber: json['set_number'] as int,
        repNumber: json['rep_number'] as int,
        startedMs: json['started_ms'] as int,
        endedMs: json['ended_ms'] as int,
        tier: FeedbackTier.fromApi(json['tier'] as String?),
        feedback: [
          for (final item in json['feedback'] as List<dynamic>? ?? const [])
            RepetitionFeedback.fromJson(item as Map<String, dynamic>),
        ],
        unmeasured: [
          for (final key in json['unmeasured'] as List<dynamic>? ?? const [])
            key as String,
        ],
        sessionStatus: json['session_status'] as String? ?? 'active',
        pause: SessionPause.fromJson(json['pause'] as Map<String, dynamic>?),
      );

  final String id;
  final int setNumber;
  final int repNumber;
  final int startedMs;
  final int endedMs;

  /// The worst of the repetition's checks.
  final FeedbackTier tier;

  /// One entry for each check at INFO or above, worst first.
  final List<RepetitionFeedback> feedback;

  /// Checks that could not be measured in this repetition.
  final List<String> unmeasured;

  /// active | paused
  final String sessionStatus;

  /// Set when this repetition paused the session.
  final SessionPause? pause;
}
