import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:physioai/app.dart';
import 'package:physioai/core/api/api_client.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/api/token_store.dart';
import 'package:physioai/features/account/account_repository.dart';
import 'package:physioai/features/admin/admin_repository.dart';
import 'package:physioai/features/admin/exercise_library_repository.dart';
import 'package:physioai/features/admin/user_management_repository.dart';
import 'package:physioai/features/auth/auth_controller.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/auth/auth_repository.dart';
import 'package:physioai/features/consent/consent_repository.dart';
import 'package:physioai/features/exercises/exercise_models.dart';
import 'package:physioai/features/notifications/notifications_repository.dart';
import 'package:physioai/features/patient/patient_repository.dart';
import 'package:physioai/features/physio/physio_repository.dart';
import 'package:physioai/features/session/pose/pose_source.dart';
import 'package:physioai/features/session/precheck.dart';
import 'package:physioai/features/session/repetitions.dart';
import 'package:physioai/features/session/session_records.dart';
import 'package:physioai/router.dart';

SessionUser user(
  UserRole role,
  String name, {
  String? physiotherapist,
  bool advisoryAcknowledged = true,
  bool passwordChangeRequired = false,
}) => SessionUser(
  account: Account(
    id: 'id-${role.apiValue}',
    fullName: name,
    role: role,
    email: '${role.apiValue}@example.test',
  ),
  physiotherapist: physiotherapist == null
      ? null
      : PersonRef(id: 'physio-1', fullName: physiotherapist),
  // Only patients are ever asked to acknowledge the advisory.
  advisoryAcknowledged: role == UserRole.patient ? advisoryAcknowledged : null,
  passwordChangeRequired: passwordChangeRequired,
);

class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({this.saved, this.patientNeedsAdvisory = false});

  SessionUser? saved;
  ApiException? failure;

  /// When true, patients come back from sign-in and registration without an
  /// acknowledged advisory, as a real new patient does.
  bool patientNeedsAdvisory;
  final signIns = <({String identifier, String password, UserRole role})>[];
  final registrations =
      <
        ({
          String fullName,
          String identifier,
          String password,
          String inviteCode,
        })
      >[];
  int signOuts = 0;

  @override
  Future<SessionUser?> restore() async => saved;

  @override
  Future<SessionUser> signIn({
    required String identifier,
    required String password,
    required UserRole role,
  }) async {
    signIns.add((identifier: identifier, password: password, role: role));
    if (failure != null) throw failure!;
    if (role == UserRole.patient) {
      return user(
        role,
        'Jane Cooper',
        physiotherapist: 'Dr. Sarah Malik',
        advisoryAcknowledged: !patientNeedsAdvisory,
      );
    }
    return user(role, 'Dr. Sarah Malik');
  }

  @override
  Future<SessionUser> register({
    required String fullName,
    required String identifier,
    required String password,
    required String inviteCode,
  }) async {
    registrations.add((
      fullName: fullName,
      identifier: identifier,
      password: password,
      inviteCode: inviteCode,
    ));
    if (failure != null) throw failure!;
    return user(
      UserRole.patient,
      fullName,
      physiotherapist: 'Dr. Sarah Malik',
      advisoryAcknowledged: !patientNeedsAdvisory,
    );
  }

  @override
  Future<void> signOut() async => signOuts++;
}

class FakePhysioRepository implements PhysioRepository {
  final codes = <InviteCode>[];

  /// The flagged queue as the server holds it, most recently flagged first.
  final flagged = <FlaggedSession>[];

  /// Sessions that can be opened, by id.
  final sessionDetails = <String, SessionDetail>{};
  ApiException? reviewFailure;
  final reviewed = <String>[];

  @override
  Future<List<FlaggedSession>> flaggedSessions({
    String state = 'unreviewed',
  }) async => [
    for (final entry in flagged)
      if (state == 'all' || entry.session.isReviewed == (state == 'reviewed'))
        entry,
  ];

  @override
  Future<SessionDetail> session(String id) async {
    final found = sessionDetails[id];
    if (found == null) {
      throw const ApiException(
        code: 'not_found',
        message: 'Session not found.',
        statusCode: 404,
      );
    }
    return found;
  }

  @override
  Future<SessionDetail> markSessionReviewed(String id) async {
    if (reviewFailure != null) throw reviewFailure!;
    reviewed.add(id);
    final at = DateTime.utc(2026, 10, 11, 9);
    SessionBrief marked(SessionBrief s) => SessionBrief(
      id: s.id,
      status: s.status,
      startedAt: s.startedAt,
      endedAt: s.endedAt,
      exercise: s.exercise,
      sets: s.sets,
      reps: s.reps,
      durationSeconds: s.durationSeconds,
      totals: s.totals,
      formScore: s.formScore,
      scoringVersion: s.scoringVersion,
      flagReasons: s.flagReasons,
      reviewedAt: at,
    );
    for (final (i, entry) in flagged.indexed) {
      if (entry.session.id == id) {
        flagged[i] = FlaggedSession(
          session: marked(entry.session),
          patient: entry.patient,
          flaggedAt: entry.flaggedAt,
          flagThreshold: entry.flagThreshold,
          reviewedBy: const PersonRef(
            id: 'physio-1',
            fullName: 'Dr. Sarah Malik',
          ),
        );
      }
    }
    return session(id);
  }

  @override
  Future<List<SessionBrief>> patientSessions(String patientId) async => [];

  @override
  Future<List<InviteCode>> inviteCodes() async => List.of(codes);

  @override
  Future<InviteCode> createInviteCode() async {
    final now = DateTime.utc(2026, 10, 7);
    final code = InviteCode(
      id: 'code-${codes.length}',
      code: 'PHY-TEST-000${codes.length}',
      createdAt: now,
      expiresAt: now.add(const Duration(days: 7)),
      status: 'active',
    );
    codes.insert(0, code);
    return code;
  }

  /// The physiotherapist's patients, the exercise picker and saved plans.
  final roster = <PatientSummary>[];
  final exercises = <ExerciseBrief>[];
  final plansByPatient = <String, List<ExercisePlan>>{};
  final assigned =
      <({String patientId, String name, List<Map<String, dynamic>> items})>[];
  ApiException? assignFailure;

  @override
  Future<List<PatientSummary>> patients() async => List.of(roster);

  @override
  Future<List<ExerciseBrief>> activeExercises() async =>
      exercises.where((exercise) => exercise.isActive).toList();

  @override
  Future<List<ExercisePlan>> plans(String patientId) async =>
      List.of(plansByPatient[patientId] ?? const []);

  @override
  Future<ExercisePlan> assignPlan({
    required String patientId,
    required String name,
    required List<PlanItemDraft> items,
  }) async {
    if (assignFailure != null) throw assignFailure!;
    assigned.add((
      patientId: patientId,
      name: name,
      items: [for (final item in items) item.toJson()],
    ));
    final now = DateTime(2026, 10, 8, 12);
    final plan = ExercisePlan(
      id: 'plan-${assigned.length}',
      name: name,
      createdAt: now,
      isActive: true,
      assignedBy: const PersonRef(id: 'physio-1', fullName: 'Dr. Sarah Malik'),
      items: [
        for (var i = 0; i < items.length; i++)
          PlanItem(
            id: 'item-$i',
            position: i + 1,
            exercise: items[i].exercise,
            sets: items[i].sets,
            reps: items[i].reps,
            restSeconds: items[i].restSeconds,
            difficulty: items[i].difficulty,
          ),
      ],
    );
    // As on the server: the previous plan is archived, never replaced.
    plansByPatient[patientId] = [
      plan,
      for (final old in plansByPatient[patientId] ?? const <ExercisePlan>[])
        ExercisePlan(
          id: old.id,
          name: old.name,
          createdAt: old.createdAt,
          archivedAt: old.archivedAt ?? now,
          isActive: false,
          assignedBy: old.assignedBy,
          items: old.items,
        ),
    ];
    return plan;
  }

  final prescriptionEditsMade = <String>[];
  final editsByPlan = <String, List<PrescriptionEdit>>{};
  ApiException? editFailure;

  @override
  Future<ExercisePlan> editPrescription({
    required String patientId,
    required String planId,
    required String itemId,
    required int sets,
    required int reps,
    required int restSeconds,
    required Difficulty difficulty,
    required String note,
  }) async {
    if (editFailure != null) throw editFailure!;
    prescriptionEditsMade.add(
      '$itemId $sets x $reps rest $restSeconds ${difficulty.apiValue} "$note"',
    );
    final now = DateTime(2026, 10, 9, 15);
    final plans = plansByPatient[patientId]!;
    final old = plans.firstWhere((p) => p.id == planId);
    final before = old.items.firstWhere((i) => i.id == itemId);
    final after = PlanItem(
      id: before.id,
      position: before.position,
      exercise: before.exercise,
      sets: sets,
      reps: reps,
      restSeconds: restSeconds,
      difficulty: difficulty,
      note: note.isEmpty ? null : note,
      revision: before.revision + 1,
      updatedAt: now,
    );
    final saved = ExercisePlan(
      id: old.id,
      name: old.name,
      createdAt: old.createdAt,
      isActive: old.isActive,
      assignedBy: old.assignedBy,
      items: [for (final i in old.items) i.id == itemId ? after : i],
    );
    plansByPatient[patientId] = [
      for (final p in plans) p.id == planId ? saved : p,
    ];
    // As on the server: what each changed field was before is kept.
    editsByPlan
        .putIfAbsent(planId, () => [])
        .add(
          PrescriptionEdit(
            id: 100 + prescriptionEditsMade.length,
            itemId: itemId,
            exerciseName: before.exercise.name,
            editedAt: now,
            editedBy: old.assignedBy,
            revision: after.revision,
            changes: [
              if (before.sets != sets)
                FieldChange(field: 'sets', before: before.sets, after: sets),
              if (before.reps != reps)
                FieldChange(field: 'reps', before: before.reps, after: reps),
              if (before.restSeconds != restSeconds)
                FieldChange(
                  field: 'rest_seconds',
                  before: before.restSeconds,
                  after: restSeconds,
                ),
              if (before.difficulty != difficulty)
                FieldChange(
                  field: 'difficulty',
                  before: before.difficulty.apiValue,
                  after: difficulty.apiValue,
                ),
              if (before.note != after.note)
                FieldChange(
                  field: 'note',
                  before: before.note,
                  after: after.note,
                ),
            ],
          ),
        );
    return saved;
  }

  @override
  Future<List<PrescriptionEdit>> prescriptionEdits({
    required String patientId,
    required String planId,
  }) async => List.of(editsByPlan[planId] ?? const []);
}

/// The signed-in person's own password and devices.
class FakeAccountRepository implements AccountRepository {
  FakeAccountRepository({List<Device>? devices, this.signedIn})
    : deviceList =
          devices ??
          [
            Device(
              id: 'this',
              name: 'Chrome on Windows',
              signedInAt: DateTime(2026, 10, 9, 9),
              lastActiveAt: DateTime(2026, 10, 9, 9, 30),
              current: true,
              ip: '203.0.113.7',
            ),
          ];

  List<Device> deviceList;

  /// Who the server says is signed in once the password has been changed.
  SessionUser? signedIn;
  ApiException? failure;
  final passwordChanges = <({String current, String next})>[];

  @override
  Future<SessionUser> changePassword({
    required String current,
    required String next,
  }) async {
    passwordChanges.add((current: current, next: next));
    if (failure != null) throw failure!;
    // As on the server: every other device is signed out.
    deviceList = [
      for (final d in deviceList)
        if (d.current) d,
    ];
    return signedIn ?? user(UserRole.patient, 'Jane Cooper');
  }

  @override
  Future<List<Device>> devices() async => List.of(deviceList);

  @override
  Future<void> signOutDevice(String id) async {
    if (failure != null) throw failure!;
    deviceList = [
      for (final d in deviceList)
        if (d.id != id) d,
    ];
  }

  @override
  Future<int> signOutOtherDevices() async {
    if (failure != null) throw failure!;
    final others = deviceList.where((d) => !d.current).length;
    deviceList = [
      for (final d in deviceList)
        if (d.current) d,
    ];
    return others;
  }
}

ManagedUser managed(
  String id,
  String name,
  UserRole role, {
  bool active = true,
  bool temporaryPassword = false,
  String? physiotherapistId,
  String? physiotherapist,
  int? patients,
  String? email,
  DateTime? lastSeen,
}) => ManagedUser(
  account: Account(
    id: id,
    fullName: name,
    role: role,
    email: email ?? '$id@example.test',
    isActive: active,
  ),
  mustChangePassword: temporaryPassword,
  lastSeenAt: lastSeen,
  physiotherapist: physiotherapistId == null
      ? null
      : PersonRef(id: physiotherapistId, fullName: physiotherapist ?? ''),
  patientCount: role == UserRole.physiotherapist ? (patients ?? 0) : null,
);

/// What an admin can do to accounts, kept in memory.
class FakeUserManagementRepository implements UserManagementRepository {
  FakeUserManagementRepository([List<ManagedUser>? users]) : list = users ?? [];

  List<ManagedUser> list;
  ApiException? failure;
  final calls = <String>[];

  ManagedUser _replace(
    String id,
    ManagedUser Function(ManagedUser old) change,
  ) {
    final saved = change(list.firstWhere((u) => u.id == id));
    list = [for (final u in list) u.id == id ? saved : u];
    return saved;
  }

  ManagedUser _copy(
    ManagedUser old, {
    String? fullName,
    String? email,
    UserRole? role,
    bool? active,
    bool? temporaryPassword,
    PersonRef? physiotherapist,
  }) => ManagedUser(
    account: Account(
      id: old.id,
      fullName: fullName ?? old.fullName,
      role: role ?? old.role,
      email: email ?? old.account.email,
      mobile: old.account.mobile,
      isActive: active ?? old.isActive,
    ),
    mustChangePassword: temporaryPassword ?? old.mustChangePassword,
    lastSeenAt: old.lastSeenAt,
    physiotherapist: physiotherapist ?? old.physiotherapist,
    patientCount: (role ?? old.role) == UserRole.physiotherapist
        ? (old.patientCount ?? 0)
        : null,
  );

  @override
  Future<List<ManagedUser>> users() async => List.of(list);

  @override
  Future<IssuedPassword> create({
    required String fullName,
    required String identifier,
    required UserRole role,
    String? physiotherapistId,
  }) async {
    calls.add(
      'create $fullName $identifier ${role.apiValue} $physiotherapistId',
    );
    if (failure != null) throw failure!;
    final created = managed(
      'new-${list.length}',
      fullName,
      role,
      email: identifier,
      temporaryPassword: true,
      physiotherapistId: physiotherapistId,
      physiotherapist: physiotherapistId == null
          ? null
          : list.firstWhere((u) => u.id == physiotherapistId).fullName,
    );
    list = [...list, created];
    return (user: created, temporaryPassword: 'Temp-4821-Kite');
  }

  @override
  Future<ManagedUser> update(
    String id, {
    required String fullName,
    required String email,
    required String mobile,
  }) async {
    calls.add('update $id $fullName $email $mobile');
    if (failure != null) throw failure!;
    return _replace(id, (old) => _copy(old, fullName: fullName, email: email));
  }

  @override
  Future<ManagedUser> setActive(String id, {required bool active}) async {
    calls.add('${active ? 'activate' : 'deactivate'} $id');
    if (failure != null) throw failure!;
    return _replace(id, (old) => _copy(old, active: active));
  }

  @override
  Future<ManagedUser> changeRole(String id, UserRole role) async {
    calls.add('role $id ${role.apiValue}');
    if (failure != null) throw failure!;
    return _replace(id, (old) => _copy(old, role: role));
  }

  @override
  Future<ManagedUser> reassign(String id, String physiotherapistId) async {
    calls.add('reassign $id $physiotherapistId');
    if (failure != null) throw failure!;
    final physio = list.firstWhere((u) => u.id == physiotherapistId);
    return _replace(
      id,
      (old) => _copy(
        old,
        physiotherapist: PersonRef(id: physio.id, fullName: physio.fullName),
      ),
    );
  }

  @override
  Future<String> resetPassword(String id) async {
    calls.add('reset $id');
    if (failure != null) throw failure!;
    _replace(id, (old) => _copy(old, temporaryPassword: true));
    return 'Temp-7733-Reed';
  }
}

class FakeAdminRepository implements AdminRepository {
  FakeAdminRepository([List<AuditEntry>? entries]) : entries = entries ?? [];

  List<AuditEntry> entries;

  @override
  Future<List<AuditEntry>> auditLog({int limit = 50}) async =>
      entries.take(limit).toList();
}

class FakeNotificationsRepository implements NotificationsRepository {
  FakeNotificationsRepository([List<AppNotification>? items])
    : items = items ?? [];

  List<AppNotification> items;
  ApiException? failure;

  AppNotification _read(AppNotification n) => AppNotification(
    id: n.id,
    kind: n.kind,
    title: n.title,
    body: n.body,
    link: n.link,
    createdAt: n.createdAt,
    readAt: n.readAt ?? DateTime(2026, 10, 8, 19),
  );

  @override
  Future<NotificationFeed> feed() async => NotificationFeed(
    unreadCount: items.where((n) => n.isUnread).length,
    items: List.of(items),
  );

  @override
  Future<void> markRead(String id) async {
    if (failure != null) throw failure!;
    items = [for (final n in items) n.id == id ? _read(n) : n];
  }

  @override
  Future<void> markAllRead() async {
    if (failure != null) throw failure!;
    items = [for (final n in items) _read(n)];
  }
}

class FakeExerciseLibraryRepository implements ExerciseLibraryRepository {
  FakeExerciseLibraryRepository([List<ExerciseTemplate>? exercises])
    : exercises = exercises ?? [];

  List<ExerciseTemplate> exercises;
  ApiException? failure;
  final created = <Map<String, dynamic>>[];
  final updated = <({String id, Map<String, dynamic> fields})>[];
  final toggled = <({String id, bool active})>[];

  ExerciseTemplate _from(
    Map<String, dynamic> fields, {
    required String id,
    required bool active,
    required int version,
  }) => ExerciseTemplate(
    id: id,
    name: fields['name'] as String,
    domain: fields['domain'] as String,
    bodyArea: fields['body_area'] as String,
    primaryTargets: fields['primary_targets'] as String,
    targetJoints: List<String>.from(fields['target_joints'] as List),
    movementPattern: fields['movement_pattern'] as String,
    instructions: fields['instructions'] as String,
    checks: [
      for (final check in fields['checks'] as List)
        SeverityCheck(
          key: check['key'] as String,
          label: check['label'] as String,
          measure: check['measure'] as String,
          unit: check['unit'] as String,
          info: check['info'] as double,
          amber: check['amber'] as double,
          red: check['red'] as double?,
          correctiveMessage: check['corrective_message'] as String,
        ),
    ],
    isActive: active,
    version: version,
    updatedAt: DateTime(2026, 10, 8, 20),
  );

  @override
  Future<List<ExerciseTemplate>> all() async => List.of(exercises);

  @override
  Future<ExerciseTemplate> create(Map<String, dynamic> fields) async {
    if (failure != null) throw failure!;
    created.add(fields);
    // As on the server: a new exercise starts switched off.
    final exercise = _from(
      fields,
      id: 'new-${created.length}',
      active: false,
      version: 1,
    );
    exercises = [...exercises, exercise];
    return exercise;
  }

  @override
  Future<ExerciseTemplate> update(
    String id,
    Map<String, dynamic> fields,
  ) async {
    if (failure != null) throw failure!;
    updated.add((id: id, fields: fields));
    final old = exercises.firstWhere((e) => e.id == id);
    final saved = _from(
      fields,
      id: id,
      active: old.isActive,
      version: old.version + 1,
    );
    exercises = [for (final e in exercises) e.id == id ? saved : e];
    return saved;
  }

  @override
  Future<ExerciseTemplate> setActive(String id, {required bool active}) async {
    if (failure != null) throw failure!;
    toggled.add((id: id, active: active));
    final old = exercises.firstWhere((e) => e.id == id);
    final saved = ExerciseTemplate(
      id: old.id,
      name: old.name,
      domain: old.domain,
      bodyArea: old.bodyArea,
      primaryTargets: old.primaryTargets,
      targetJoints: old.targetJoints,
      movementPattern: old.movementPattern,
      instructions: old.instructions,
      checks: old.checks,
      isActive: active,
      version: old.version,
      updatedAt: old.updatedAt,
    );
    exercises = [for (final e in exercises) e.id == id ? saved : e];
    return saved;
  }
}

class FakePatientRepository implements PatientRepository {
  ExercisePlan? plan;

  @override
  Future<ExercisePlan?> currentPlan() async => plan;

  /// What the camera must show, by plan item id.
  final requirements = <String, PrecheckRequirements>{};
  ApiException? startFailure;
  ApiException? endFailure;
  final started = <({String itemId, Map<String, dynamic> evidence})>[];
  final ended = <String>[];

  @override
  Future<PrecheckRequirements> precheckRequirements(String itemId) async {
    final found = requirements[itemId];
    if (found == null) {
      throw const ApiException(
        code: 'not_found',
        message: 'That exercise is not in your current plan.',
        statusCode: 404,
      );
    }
    return found;
  }

  /// The checks a session is judged against once it starts.
  List<SessionCheck> checks = const [];
  String _status = 'active';
  SessionPause? _pause;

  ExerciseSession _session(String id) => ExerciseSession(
    id: id,
    status: _status,
    startedAt: DateTime(2026, 10, 9, 17),
    endedAt: _status == 'completed' ? DateTime(2026, 10, 9, 17, 5) : null,
    checks: checks,
    totals: SessionTotals(
      repetitions: _storedRepetitions.length,
      ok: _count(FeedbackTier.ok),
      info: _count(FeedbackTier.info),
      amber: _count(FeedbackTier.amber),
      red: _count(FeedbackTier.red),
    ),
    pause: _pause,
  );

  int _count(FeedbackTier tier) =>
      _storedRepetitions.values.where((stored) => stored.tier == tier).length;

  /// The session of the same exercise before this one, if there was one.
  PreviousSession? previous;

  /// How long the server says the session lasted.
  int sessionSeconds = 300;

  /// The server's rule: what each repetition is worth, averaged.
  SessionSummary _summary() {
    const points = {
      FeedbackTier.ok: 100,
      FeedbackTier.info: 85,
      FeedbackTier.amber: 55,
      FeedbackTier.red: 0,
    };
    final stored = _storedRepetitions.values;
    final score = stored.isEmpty
        ? null
        : (stored.fold(0, (sum, rep) => sum + points[rep.tier]!) /
                  stored.length)
              .round();
    final before = previous?.formScore;
    return SessionSummary(
      durationSeconds: sessionSeconds,
      totals: _session('').totals,
      formScore: score,
      scoredRepetitions: stored.length,
      scoringVersion: 'rules-1',
      previous: previous,
      scoreChange: score == null || before == null ? null : score - before,
    );
  }

  /// The patient's finished sessions, most recent first.
  final history = <SessionBrief>[];
  final sessionDetails = <String, SessionDetail>{};
  ApiException? historyFailure;

  @override
  Future<List<SessionBrief>> sessions({
    String? exerciseId,
    DateTime? since,
    DateTime? until,
  }) async {
    if (historyFailure != null) throw historyFailure!;
    return [
      for (final session in history)
        if ((exerciseId == null || session.exercise.id == exerciseId) &&
            (since == null || !session.startedAt.isBefore(since)) &&
            (until == null || session.startedAt.isBefore(until)))
          session,
    ];
  }

  @override
  Future<SessionDetail> sessionDetail(String id) async {
    final found = sessionDetails[id];
    if (found == null) {
      throw const ApiException(
        code: 'not_found',
        message: 'Session not found.',
        statusCode: 404,
      );
    }
    return found;
  }

  @override
  Future<ExerciseSession> startSession({
    required String itemId,
    required Map<String, dynamic> evidence,
  }) async {
    started.add((itemId: itemId, evidence: evidence));
    if (startFailure != null) throw startFailure!;
    return _session('session-${started.length}');
  }

  /// Every repetition the app tried to store, including retries.
  final repetitionWrites = <({String sessionId, RepetitionDraft repetition})>[];
  ApiException? repetitionFailure;
  final _storedRepetitions = <String, RecordedRepetition>{};

  /// What the server would hold: one repetition for each key it was sent.
  List<RecordedRepetition> get storedRepetitions =>
      List.unmodifiable(_storedRepetitions.values);

  /// The server's rule: the first threshold reached, from the top down.
  static FeedbackTier _tierOf(double value, SessionCheck check) {
    if (check.red != null && value >= check.red!) return FeedbackTier.red;
    if (value >= check.amber) return FeedbackTier.amber;
    if (value >= check.info) return FeedbackTier.info;
    return FeedbackTier.ok;
  }

  @override
  Future<RecordedRepetition> recordRepetition({
    required String sessionId,
    required RepetitionDraft repetition,
  }) async {
    repetitionWrites.add((sessionId: sessionId, repetition: repetition));
    if (repetitionFailure != null) throw repetitionFailure!;
    // Like the server, a key seen before returns what was stored the first time.
    final key = '$sessionId/${repetition.clientKey}';
    final before = _storedRepetitions[key];
    if (before != null) return before;
    if (_status == 'paused') {
      throw const ApiException(
        code: 'session_paused',
        message: 'Read the message on screen before you continue.',
        statusCode: 409,
      );
    }
    if (_status != 'active') {
      throw const ApiException(
        code: 'session_not_active',
        message: 'This session has already ended.',
        statusCode: 409,
      );
    }

    final feedback = <RepetitionFeedback>[
      for (final check in checks)
        if (repetition.measures[check.key] case final value?)
          if (_tierOf(value, check) != FeedbackTier.ok)
            RepetitionFeedback(
              check: check.key,
              label: check.label,
              tier: _tierOf(value, check),
              value: value,
              message: check.message,
            ),
    ]..sort((a, b) => b.tier.index.compareTo(a.tier.index));
    final tier = feedback.isEmpty ? FeedbackTier.ok : feedback.first.tier;
    final id = 'repetition-${_storedRepetitions.length + 1}';
    if (tier == FeedbackTier.red) {
      _status = 'paused';
      _pause = SessionPause(
        repetitionId: id,
        check: feedback.first.check,
        message: feedback.first.message,
      );
    }
    return _storedRepetitions[key] = RecordedRepetition(
      id: id,
      setNumber: repetition.setNumber,
      repNumber: repetition.repNumber,
      startedMs: repetition.startedMs,
      endedMs: repetition.endedMs,
      tier: tier,
      feedback: feedback,
      unmeasured: [
        for (final check in checks)
          if (repetition.measures[check.key] == null) check.key,
      ],
      sessionStatus: _status,
      pause: tier == FeedbackTier.red ? _pause : null,
    );
  }

  /// The session is paused somewhere the app did not see, as it would be
  /// after a RED repetition sent from another tab.
  void pauseElsewhere(String message) {
    _status = 'paused';
    _pause = SessionPause(
      repetitionId: 'repetition-elsewhere',
      check: 'trunk_lean',
      message: message,
    );
  }

  int sessionReads = 0;

  @override
  Future<ExerciseSession> session(String id) async {
    sessionReads++;
    return _session(id);
  }

  ApiException? acknowledgeFailure;
  final acknowledged = <String>[];

  @override
  Future<ExerciseSession> acknowledgePause({
    required String sessionId,
    required String repetitionId,
  }) async {
    if (acknowledgeFailure != null) throw acknowledgeFailure!;
    if (_pause?.repetitionId != repetitionId) {
      throw const ApiException(
        code: 'wrong_repetition',
        message: 'That is not the repetition this session is paused on.',
        statusCode: 409,
      );
    }
    acknowledged.add(repetitionId);
    _status = 'active';
    _pause = null;
    return _session(sessionId);
  }

  @override
  Future<ExerciseSession> endSession(String id) async {
    if (endFailure != null) throw endFailure!;
    ended.add(id);
    _status = 'completed';
    _pause = null;
    final session = _session(id);
    return ExerciseSession(
      id: session.id,
      status: session.status,
      startedAt: session.startedAt,
      endedAt: session.endedAt,
      checks: session.checks,
      totals: session.totals,
      summary: _summary(),
    );
  }
}

class FakeConsentRepository implements ConsentRepository {
  static const disclaimer = Disclaimer(
    version: '2026-10',
    title: 'Before your first session',
    intro: 'A few things to know so you can exercise safely and confidently.',
    points: [
      DisclaimerPoint(
        heading: 'PhysioAI gives movement feedback.',
        body: 'It suggests small corrections in real time.',
      ),
      DisclaimerPoint(
        heading: 'It does not diagnose.',
        body: 'It does not replace your physiotherapist.',
      ),
    ],
    caution: 'If you feel sharp pain, stop and contact your physiotherapist.',
    acknowledgment:
        'I understand that PhysioAI provides movement feedback only.',
  );

  DateTime? acknowledgedAt;
  ApiException? failure;
  final acknowledgedVersions = <String>[];

  @override
  Future<ConsentStatus> status() async => ConsentStatus(
    disclaimer: disclaimer,
    acknowledged: acknowledgedAt != null,
    acknowledgedAt: acknowledgedAt,
  );

  @override
  Future<ConsentStatus> acknowledge(String version) async {
    if (failure != null) throw failure!;
    acknowledgedVersions.add(version);
    acknowledgedAt = DateTime(2026, 10, 8, 18, 30);
    return status();
  }
}

Future<FakeAuthRepository> pumpApp(
  WidgetTester tester, {
  FakeAuthRepository? auth,
  FakePhysioRepository? physio,
  FakeConsentRepository? consent,
  FakePatientRepository? patient,
  FakeNotificationsRepository? notifications,
  FakeExerciseLibraryRepository? library,
  FakeAccountRepository? account,
  FakeUserManagementRepository? users,
  FakeAdminRepository? admin,
  PoseSource? camera,
}) async {
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repository = auth ?? FakeAuthRepository();
  await tester.pumpWidget(
    ProviderScope(
      // A new key every time, so a test that starts the app more than once
      // (one role after another) never carries the previous sign-in over.
      key: UniqueKey(),
      overrides: [
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
        authRepositoryProvider.overrideWithValue(repository),
        physioRepositoryProvider.overrideWithValue(
          physio ?? FakePhysioRepository(),
        ),
        consentRepositoryProvider.overrideWithValue(
          consent ?? FakeConsentRepository(),
        ),
        patientRepositoryProvider.overrideWithValue(
          patient ?? FakePatientRepository(),
        ),
        notificationsRepositoryProvider.overrideWithValue(
          notifications ?? FakeNotificationsRepository(),
        ),
        exerciseLibraryRepositoryProvider.overrideWithValue(
          library ?? FakeExerciseLibraryRepository(),
        ),
        accountRepositoryProvider.overrideWithValue(
          account ?? FakeAccountRepository(),
        ),
        userManagementRepositoryProvider.overrideWithValue(
          users ?? FakeUserManagementRepository(),
        ),
        adminRepositoryProvider.overrideWithValue(
          admin ?? FakeAdminRepository(),
        ),
        // Without one, the app has no camera, as on an unsupported device.
        if (camera != null)
          poseSourceProvider.overrideWith((ref) {
            ref.onDispose(camera.stop);
            return camera;
          }),
      ],
      child: const PhysioAiApp(),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

/// Scrolls the widget with [key] into view and taps it.
Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

/// Scrolls the field with [key] into view and replaces its text.
Future<void> fill(WidgetTester tester, String key, String value) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.enterText(find.byKey(Key(key)), value);
  await tester.pumpAndSettle();
}

/// Welcome -> "Choose your role".
Future<void> openRoleChooser(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(OutlinedButton, 'Sign In'));
  await tester.pumpAndSettle();
}

/// Welcome -> "Choose your role" -> the sign-in form for [role].
Future<void> openSignInAs(WidgetTester tester, UserRole role) async {
  await openRoleChooser(tester);
  await tester.tap(find.byKey(Key('role-${role.apiValue}')));
  await tester.pumpAndSettle();
}

/// Welcome -> role chooser -> patient sign-in -> "Create an account".
Future<void> openRegistration(WidgetTester tester) async {
  await openSignInAs(tester, UserRole.patient);
  await tester.ensureVisible(find.byKey(const Key('create-account')));
  await tester.tap(find.byKey(const Key('create-account')));
  await tester.pumpAndSettle();
}

void main() {
  group('redirectFor', () {
    const signedOut = SignedOut();
    final patient = SignedIn(user(UserRole.patient, 'Jane Cooper'));
    final admin = SignedIn(user(UserRole.admin, 'Alex Morgan'));

    test('signed-out visitors can only open the public screens', () {
      expect(redirectFor(signedOut, '/'), isNull);
      expect(redirectFor(signedOut, '/register'), isNull);
      expect(redirectFor(signedOut, '/sign-in'), isNull);
      expect(redirectFor(signedOut, '/sign-in/admin'), isNull);
      expect(redirectFor(signedOut, '/admin/users'), '/sign-in');
      expect(redirectFor(signedOut, '/patient'), '/sign-in');
    });

    test('a signed-in user is kept inside their own role area', () {
      expect(redirectFor(patient, '/patient/plan'), isNull);
      expect(redirectFor(patient, '/admin'), '/patient');
      expect(redirectFor(patient, '/physio/patients'), '/patient');
      expect(redirectFor(admin, '/admin/audit-log'), isNull);
      expect(redirectFor(admin, '/sign-in'), '/admin');
      expect(redirectFor(admin, '/sign-in/patient'), '/admin');
    });

    test(
      'a path that only shares a prefix is not treated as the same area',
      () {
        expect(redirectFor(patient, '/patients'), '/patient');
        expect(redirectFor(signedOut, '/sign-in-admin'), '/sign-in');
      },
    );

    test('the address is left alone while the saved session is checked', () {
      expect(redirectFor(const AuthLoading(), '/physio/patients'), isNull);
      expect(redirectFor(const AuthLoading(), '/sign-in/admin'), isNull);
    });
  });

  testWidgets('the first sign-in step only asks for a role', (tester) async {
    await pumpApp(tester);
    expect(
      find.text('Smarter rehabilitation.\nBetter movement.'),
      findsOneWidget,
    );

    await openRoleChooser(tester);

    expect(find.text('Choose your role'), findsOneWidget);
    expect(find.text('Login as Patient'), findsOneWidget);
    expect(find.text('Login as Physiotherapist'), findsOneWidget);
    expect(find.text('Login as Admin'), findsOneWidget);
    // No form and no account creation on this screen.
    expect(find.byKey(const Key('sign-in-identifier')), findsNothing);
    expect(find.byKey(const Key('sign-in-password')), findsNothing);
    expect(find.byKey(const Key('sign-in-submit')), findsNothing);
    expect(find.byKey(const Key('create-account')), findsNothing);
  });

  testWidgets('Get Started also begins with choosing a role', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Get Started'));
    await tester.pumpAndSettle();

    expect(find.text('Choose your role'), findsOneWidget);
  });

  testWidgets('patients can sign in or create an account on the second step', (
    tester,
  ) async {
    await pumpApp(tester);

    await openSignInAs(tester, UserRole.patient);

    expect(find.text('Sign in as Patient'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);
    expect(find.byKey(const Key('create-account')), findsOneWidget);
  });

  for (final role in [UserRole.physiotherapist, UserRole.admin]) {
    testWidgets('${role.label} gets sign-in only, with no account creation', (
      tester,
    ) async {
      await pumpApp(tester);

      await openSignInAs(tester, role);

      expect(find.text('Sign in as ${role.label}'), findsOneWidget);
      expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);
      expect(find.byKey(const Key('create-account')), findsNothing);
      expect(find.text('Create an account'), findsNothing);
      expect(
        find.text(
          '${role.label} accounts are created by your clinic administrator.',
        ),
        findsOneWidget,
      );
    });
  }

  testWidgets('Change role goes back to the role step', (tester) async {
    await pumpApp(tester);
    await openSignInAs(tester, UserRole.admin);

    await tester.tap(find.byKey(const Key('change-role')));
    await tester.pumpAndSettle();

    expect(find.text('Choose your role'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-submit')), findsNothing);
  });

  testWidgets('an unknown role in the address falls back to the role step', (
    tester,
  ) async {
    await pumpApp(tester);

    GoRouter.of(
      tester.element(find.byType(Scaffold).first),
    ).go('/sign-in/nurse');
    await tester.pumpAndSettle();

    expect(find.text('Choose your role'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-submit')), findsNothing);
  });

  testWidgets('empty form is rejected without calling the server', (
    tester,
  ) async {
    final auth = await pumpApp(tester);
    await openSignInAs(tester, UserRole.patient);

    await tester.tap(find.byKey(const Key('sign-in-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Enter your email or mobile number.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    expect(auth.signIns, isEmpty);
  });

  testWidgets("signing in sends the chosen role and opens that role's home", (
    tester,
  ) async {
    final auth = await pumpApp(tester);
    await openSignInAs(tester, UserRole.physiotherapist);

    await tester.enterText(
      find.byKey(const Key('sign-in-identifier')),
      '  dr.sarah@example.test ',
    );
    await tester.enterText(
      find.byKey(const Key('sign-in-password')),
      'Physio-Pass-1',
    );
    await tester.tap(find.byKey(const Key('sign-in-submit')));
    await tester.pumpAndSettle();

    expect(auth.signIns.single, (
      identifier: 'dr.sarah@example.test',
      password: 'Physio-Pass-1',
      role: UserRole.physiotherapist,
    ));
    expect(find.text('Invite a patient'), findsOneWidget);
    expect(find.text('Plan Builder'), findsOneWidget);
    expect(find.text('Users & Roles'), findsNothing);
  });

  testWidgets('a locked account shows the server message and stays on the form', (
    tester,
  ) async {
    final auth = await pumpApp(tester);
    auth.failure = const ApiException(
      code: 'account_locked',
      message:
          'Too many unsuccessful sign-in attempts. Try again in about 15 minutes.',
      statusCode: 423,
      retryAfterSeconds: 900,
    );
    await openSignInAs(tester, UserRole.patient);

    await tester.enterText(
      find.byKey(const Key('sign-in-identifier')),
      'jane@example.test',
    );
    await tester.enterText(
      find.byKey(const Key('sign-in-password')),
      'wrong-password',
    );
    await tester.tap(find.byKey(const Key('sign-in-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sign-in-error')), findsOneWidget);
    expect(
      find.textContaining('Too many unsuccessful sign-in attempts'),
      findsOneWidget,
    );
    expect(find.text('Sign in as Patient'), findsOneWidget);
  });

  testWidgets(
    'registration checks the form, then links the patient to their physiotherapist',
    (tester) async {
      final auth = await pumpApp(tester);
      await openRegistration(tester);

      await tester.enterText(
        find.byKey(const Key('register-name')),
        'Jane Cooper',
      );
      await tester.enterText(
        find.byKey(const Key('register-identifier')),
        'jane@example.test',
      );
      await tester.enterText(
        find.byKey(const Key('register-password')),
        'Recover-2026',
      );
      await tester.enterText(
        find.byKey(const Key('register-confirm')),
        'Recover-2027',
      );
      await tester.ensureVisible(find.byKey(const Key('register-submit')));
      await tester.tap(find.byKey(const Key('register-submit')));
      await tester.pumpAndSettle();

      expect(find.text('The passwords do not match.'), findsOneWidget);
      expect(
        find.text('Enter the invite code from your physiotherapist.'),
        findsOneWidget,
      );
      expect(auth.registrations, isEmpty);

      await tester.enterText(
        find.byKey(const Key('register-confirm')),
        'Recover-2026',
      );
      await tester.enterText(
        find.byKey(const Key('register-invite')),
        ' phy-4k7m-9qxd ',
      );
      await tester.tap(find.byKey(const Key('register-submit')));
      await tester.pumpAndSettle();

      expect(auth.registrations.single.inviteCode, 'phy-4k7m-9qxd');
      expect(find.byKey(const Key('linked-physio')), findsOneWidget);
      expect(find.text('Dr. Sarah Malik'), findsOneWidget);
    },
  );

  testWidgets('an invalid invite code is explained on the registration form', (
    tester,
  ) async {
    final auth = await pumpApp(tester);
    auth.failure = const ApiException(
      code: 'invite_invalid',
      message:
          'This invite code is not valid or has expired. Ask your physiotherapist for a new one.',
      statusCode: 400,
    );
    await openRegistration(tester);

    await tester.enterText(
      find.byKey(const Key('register-name')),
      'Jane Cooper',
    );
    await tester.enterText(
      find.byKey(const Key('register-identifier')),
      '0300 1234567',
    );
    await tester.enterText(
      find.byKey(const Key('register-password')),
      'Recover-2026',
    );
    await tester.enterText(
      find.byKey(const Key('register-confirm')),
      'Recover-2026',
    );
    await tester.enterText(
      find.byKey(const Key('register-invite')),
      'PHY-NOPE-NOPE',
    );
    await tester.ensureVisible(find.byKey(const Key('register-submit')));
    await tester.tap(find.byKey(const Key('register-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('register-error')), findsOneWidget);
    expect(find.textContaining('not valid or has expired'), findsOneWidget);
    expect(find.text('Create your account'), findsOneWidget);
  });

  testWidgets('registration links back to the patient sign-in', (tester) async {
    await pumpApp(tester);
    await openRegistration(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Sign In').first);
    await tester.pumpAndSettle();

    expect(find.text('Sign in as Patient'), findsOneWidget);
  });

  testWidgets(
    'a saved session opens the role home directly and logging out returns to the role step',
    (tester) async {
      final auth = await pumpApp(
        tester,
        auth: FakeAuthRepository(
          saved: user(UserRole.physiotherapist, 'Dr. Sarah Malik'),
        ),
      );

      expect(find.text('Invite a patient'), findsOneWidget);

      await tester.tap(find.byKey(const Key('generate-invite')));
      await tester.pumpAndSettle();
      expect(find.text('PHY-TEST-0000'), findsOneWidget);

      await tester.tap(find.byKey(const Key('sign-out')));
      await tester.pumpAndSettle();

      expect(auth.signOuts, 1);
      expect(find.text('Choose your role'), findsOneWidget);
    },
  );
}
