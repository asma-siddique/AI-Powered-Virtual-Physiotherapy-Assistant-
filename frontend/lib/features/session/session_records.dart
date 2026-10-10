import '../auth/auth_models.dart';
import '../exercises/exercise_models.dart';
import 'repetitions.dart';

/// The session of the same exercise before this one, for the comparison.
class PreviousSession {
  const PreviousSession({
    required this.id,
    required this.endedAt,
    required this.repetitions,
    this.formScore,
  });

  factory PreviousSession.fromJson(Map<String, dynamic> json) =>
      PreviousSession(
        id: json['id'] as String,
        endedAt: DateTime.parse(json['ended_at'] as String),
        repetitions: json['repetitions'] as int,
        formScore: json['form_score'] as int?,
      );

  final String id;
  final DateTime endedAt;
  final int repetitions;

  /// Null when that session had nothing to score.
  final int? formScore;
}

/// What a finished session came to (US 4.2). The server builds it once the
/// session has ended, from repetitions it has already classified.
class SessionSummary {
  const SessionSummary({
    required this.durationSeconds,
    this.totals = const SessionTotals(),
    this.formScore,
    this.scoredRepetitions = 0,
    this.scoringVersion,
    this.previous,
    this.scoreChange,
  });

  static SessionSummary? fromJson(Map<String, dynamic>? json) => json == null
      ? null
      : SessionSummary(
          durationSeconds: json['duration_seconds'] as int,
          totals: SessionTotals.fromJson(
            json['totals'] as Map<String, dynamic>?,
          ),
          formScore: json['form_score'] as int?,
          scoredRepetitions: json['scored_repetitions'] as int? ?? 0,
          scoringVersion: json['scoring_version'] as String?,
          previous: json['previous'] == null
              ? null
              : PreviousSession.fromJson(
                  json['previous'] as Map<String, dynamic>,
                ),
          scoreChange: json['score_change'] as int?,
        );

  final int durationSeconds;
  final SessionTotals totals;

  /// 0 to 100. Null, never 0, when no repetition could be scored.
  final int? formScore;
  final int scoredRepetitions;

  /// Which rule or model produced the score.
  final String? scoringVersion;
  final PreviousSession? previous;

  /// This score minus the previous one; null when either is missing.
  final int? scoreChange;

  /// The comparison with the previous session, in the patient's words.
  String get trend {
    final before = previous;
    if (before == null) {
      return 'This is your first session of this exercise.';
    }
    final change = scoreChange;
    if (change == null) {
      return formScore == null
          ? 'There was nothing to score this time, so there is no comparison.'
          : 'Your last session had nothing to score, so there is no comparison.';
    }
    if (change == 0) {
      return 'The same as your last session (${before.formScore}).';
    }
    final points = change.abs() == 1 ? '1 point' : '${change.abs()} points';
    return change > 0
        ? 'Up $points from your last session (${before.formScore}).'
        : 'Down $points from your last session (${before.formScore}).';
  }
}

/// One session in a list: the patient's history (US 5.1) and the
/// physiotherapist's views (US 5.2).
class SessionBrief {
  const SessionBrief({
    required this.id,
    required this.status,
    required this.startedAt,
    this.endedAt,
    required this.exercise,
    required this.sets,
    required this.reps,
    required this.durationSeconds,
    this.totals = const SessionTotals(),
    this.formScore,
    this.scoringVersion,
    this.flagReasons = const [],
    this.reviewedAt,
  });

  factory SessionBrief.fromJson(Map<String, dynamic> json) => SessionBrief(
    id: json['id'] as String,
    status: json['status'] as String,
    startedAt: DateTime.parse(json['started_at'] as String),
    endedAt: DateTime.tryParse(json['ended_at'] as String? ?? ''),
    exercise: ExerciseBrief.fromJson(json['exercise'] as Map<String, dynamic>),
    sets: json['sets'] as int,
    reps: json['reps'] as int,
    durationSeconds: json['duration_seconds'] as int,
    totals: SessionTotals.fromJson(json['totals'] as Map<String, dynamic>?),
    formScore: json['form_score'] as int?,
    scoringVersion: json['scoring_version'] as String?,
    flagReasons: [
      for (final reason in json['flag_reasons'] as List<dynamic>? ?? const [])
        reason as String,
    ],
    reviewedAt: DateTime.tryParse(json['reviewed_at'] as String? ?? ''),
  );

  final String id;

  /// completed | abandoned; active | paused only in a physiotherapist's
  /// queue, for a session flagged while the patient is still in it.
  final String status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final ExerciseBrief exercise;
  final int sets;
  final int reps;
  final int durationSeconds;
  final SessionTotals totals;

  /// Null when the session had nothing to score. Never shown as 0.
  final int? formScore;
  final String? scoringVersion;

  /// red | low_score; empty when the session was not flagged.
  final List<String> flagReasons;
  final DateTime? reviewedAt;

  bool get isUnderWay => status == 'active' || status == 'paused';

  /// Left open (a closed tab, a lost connection) and closed by the server.
  bool get wasLeftOpen => status == 'abandoned';
  bool get isReviewed => reviewedAt != null;
}

/// One repetition of a stored session.
class RepetitionDetail {
  const RepetitionDetail({
    required this.setNumber,
    required this.repNumber,
    required this.startedMs,
    required this.endedMs,
    required this.tier,
    this.feedback = const [],
    this.unmeasured = const [],
  });

  factory RepetitionDetail.fromJson(Map<String, dynamic> json) =>
      RepetitionDetail(
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
      );

  final int setNumber;
  final int repNumber;
  final int startedMs;
  final int endedMs;
  final FeedbackTier tier;
  final List<RepetitionFeedback> feedback;
  final List<String> unmeasured;
}

/// Everything about one session.
class SessionDetail extends SessionBrief {
  const SessionDetail({
    required super.id,
    required super.status,
    required super.startedAt,
    super.endedAt,
    required super.exercise,
    required super.sets,
    required super.reps,
    required super.durationSeconds,
    super.totals,
    super.formScore,
    super.scoringVersion,
    super.flagReasons,
    super.reviewedAt,
    this.checks = const [],
    this.repetitions = const [],
  });

  factory SessionDetail.fromJson(Map<String, dynamic> json) {
    final brief = SessionBrief.fromJson(json);
    return SessionDetail(
      id: brief.id,
      status: brief.status,
      startedAt: brief.startedAt,
      endedAt: brief.endedAt,
      exercise: brief.exercise,
      sets: brief.sets,
      reps: brief.reps,
      durationSeconds: brief.durationSeconds,
      totals: brief.totals,
      formScore: brief.formScore,
      scoringVersion: brief.scoringVersion,
      flagReasons: brief.flagReasons,
      reviewedAt: brief.reviewedAt,
      checks: [
        for (final check in json['checks'] as List<dynamic>? ?? const [])
          SessionCheck.fromJson(check as Map<String, dynamic>),
      ],
      repetitions: [
        for (final item in json['repetitions'] as List<dynamic>? ?? const [])
          RepetitionDetail.fromJson(item as Map<String, dynamic>),
      ],
    );
  }

  /// The thresholds the session was judged against.
  final List<SessionCheck> checks;

  /// In the order performed.
  final List<RepetitionDetail> repetitions;
}

/// A session in a physiotherapist's flagged queue (US 5.2).
class FlaggedSession {
  const FlaggedSession({
    required this.session,
    required this.patient,
    required this.flaggedAt,
    this.flagThreshold,
    this.reviewedBy,
  });

  factory FlaggedSession.fromJson(Map<String, dynamic> json) => FlaggedSession(
    session: SessionBrief.fromJson(json['session'] as Map<String, dynamic>),
    patient: PersonRef.fromJson(json['patient'] as Map<String, dynamic>),
    flaggedAt: DateTime.parse(json['flagged_at'] as String),
    flagThreshold: json['flag_threshold'] as int?,
    reviewedBy: json['reviewed_by'] == null
        ? null
        : PersonRef.fromJson(json['reviewed_by'] as Map<String, dynamic>),
  );

  final SessionBrief session;
  final PersonRef patient;
  final DateTime flaggedAt;

  /// The score threshold in force when it was flagged for a low score.
  final int? flagThreshold;
  final PersonRef? reviewedBy;

  /// Why it is in the queue, in the physiotherapist's words.
  List<String> get reasons => [
    if (session.flagReasons.contains('red')) 'Paused for safety',
    if (session.flagReasons.contains('low_score'))
      flagThreshold == null ? 'Low score' : 'Score below $flagThreshold',
  ];
}

/// "4 min 05 s", "32 seconds".
String formatDuration(int seconds) {
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  if (minutes == 0) return rest == 1 ? '1 second' : '$rest seconds';
  return '$minutes min ${rest.toString().padLeft(2, '0')} s';
}
