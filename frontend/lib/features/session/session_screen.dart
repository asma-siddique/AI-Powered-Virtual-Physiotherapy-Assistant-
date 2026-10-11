import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/animations.dart';
import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/hologram/holo_figure.dart';
import '../../core/widgets/ui_components.dart';
import '../patient/patient_repository.dart';
import '../shell/page_widgets.dart';
import 'live_session.dart';
import 'pain.dart';
import 'pose/pose_models.dart';
import 'pose/pose_source.dart';
import 'precheck.dart';
import '../progress/session_widgets.dart';
import 'repetitions.dart';
import 'session_records.dart';

/// One exercise in front of the camera: first the camera check, then the
/// session itself. The session starts by itself once the setup has held good
/// for a moment, because the patient is standing well back from the device.
/// Nothing is counted or scored before that.
///
/// During the session the app counts repetitions and sends what it measured
/// in each one. Feedback on screen always comes from the server's reply, so
/// there is a stored record behind everything the patient is shown, and a RED
/// repetition pauses the session until its message is acknowledged.
class SessionScreen extends ConsumerStatefulWidget {
  const SessionScreen({super.key, required this.itemId});

  /// The exercise of the patient's current plan to perform.
  final String itemId;

  @override
  ConsumerState<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends ConsumerState<SessionScreen> {
  /// Holds the camera for as long as this screen is open. The camera is
  /// listened to, not just read: read without a listener, its provider would
  /// switch it off again a moment after handing it over, leaving a live
  /// picture with no body tracking behind it.
  late final ProviderSubscription<PoseSource> _cameraHold;
  late final PoseSource _source;
  StreamSubscription<PoseFrame>? _frames;
  ProviderSubscription<AsyncValue<PrecheckRequirements>>? _requirements;
  Timer? _clock;

  PrecheckTracker? _tracker;
  PoseFrame? _frame;
  SetupReading? _reading;
  CameraException? _cameraProblem;
  bool _cameraOn = false;

  ExerciseSession? _session;

  /// The optional pain rating chosen during the camera check. It is sent
  /// once the session exists, and never holds the session up.
  int? _painBefore;
  bool _painBeforeSaved = false;
  bool _starting = false;
  bool _ending = false;
  String? _startError;
  Duration _elapsed = Duration.zero;

  LiveSessionEngine? _engine;

  /// The camera's clock at the first frame of the session.
  double? _sessionStartMs;

  /// Counted repetitions not yet stored, oldest first.
  final _unsent = <RepetitionDraft>[];

  /// The sending that is under way, if any; there is never more than one.
  Future<void>? _sending;
  Timer? _retry;

  /// The last repetition the server stored: where on-screen feedback comes from.
  RecordedRepetition? _lastStored;
  String? _saveProblem;

  /// Set when the session can take no more repetitions (ended elsewhere).
  String? _stopped;

  SessionPause? _pause;
  bool _acknowledging = false;
  String? _pauseError;

  /// The patient has ticked "I understand" on the safety pause.
  bool _understood = false;

  /// How the server classified each stored repetition, by set and number,
  /// for the row of dots under the counter.
  final _tiers = <(int, int), FeedbackTier>{};

  /// The session once it has ended, for the summary.
  ExerciseSession? _finished;

  @override
  void initState() {
    super.initState();
    _cameraHold = ref.listenManual(poseSourceProvider, (_, _) {});
    _source = _cameraHold.read();
    _requirements = ref.listenManual(
      precheckRequirementsProvider(widget.itemId),
      (_, next) {
        final requirements = next.valueOrNull;
        if (requirements != null && _tracker == null) _begin(requirements);
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _clock?.cancel();
    _retry?.cancel();
    _frames?.cancel();
    _requirements?.close();
    // Letting go of the camera is what switches it off.
    _cameraHold.close();
    super.dispose();
  }

  Future<void> _begin(PrecheckRequirements requirements) async {
    _tracker = PrecheckTracker(requirements);
    await _startCamera();
  }

  Future<void> _startCamera() async {
    setState(() => _cameraProblem = null);
    try {
      await _source.start();
    } on CameraException catch (problem) {
      if (mounted) setState(() => _cameraProblem = problem);
      return;
    }
    if (!mounted) return;
    setState(() => _cameraOn = true);
    _frames = _source.frames.listen(_onFrame);
  }

  void _onFrame(PoseFrame frame) {
    final tracker = _tracker;
    if (tracker == null || !mounted) return;
    if (_session != null) _follow(frame);
    setState(() {
      _frame = frame;
      // During the session the same judgment only reports whether the
      // patient is still in view; the hold is not restarted.
      _reading = _session == null
          ? tracker.add(frame)
          : judgeSetup(frame, tracker.requirements);
    });
    if (_session == null &&
        tracker.ready &&
        !_starting &&
        _startError == null) {
      _start();
    }
  }

  /// Sends the pain rating chosen before the session, if there is one.
  /// It is optional information, so a failure is not shown; it is tried
  /// once more when the session ends.
  Future<void> _savePainBefore() async {
    final session = _session;
    final score = _painBefore;
    if (session == null || score == null || _painBeforeSaved) return;
    try {
      await ref
          .read(patientRepositoryProvider)
          .logPain(sessionId: session.id, moment: 'before', score: score);
      _painBeforeSaved = true;
    } on ApiException catch (_) {}
  }

  Future<void> _start() async {
    final tracker = _tracker!;
    setState(() => _starting = true);
    try {
      final session = await ref
          .read(patientRepositoryProvider)
          .startSession(itemId: widget.itemId, evidence: tracker.evidence());
      if (!mounted) return;
      final requirements = tracker.requirements;
      setState(() {
        _session = session;
        _starting = false;
        _pause = session.pause;
        _understood = false;
        _engine = LiveSessionEngine(
          exerciseSlug: requirements.exercise.slug,
          targetJoints: requirements.exercise.targetJoints,
          checkKeys: [for (final check in session.checks) check.key],
          sets: requirements.sets,
          repsPerSet: requirements.reps,
          minVisibility: requirements.minVisibility,
          aspectRatio: _source.aspectRatio,
        );
      });
      unawaited(_savePainBefore());
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      tracker.reset();
      setState(() {
        _starting = false;
        // Held until the patient asks to try again, so a refusal is read
        // rather than retried in a loop.
        _startError = error.message;
      });
    }
  }

  void _retryStart() {
    _tracker?.reset();
    setState(() => _startError = null);
  }

  /// Follows the movement during the session and queues each repetition as
  /// it is completed.
  void _follow(PoseFrame frame) {
    final engine = _engine;
    if (engine == null ||
        _pause != null ||
        _stopped != null ||
        _finished != null ||
        _ending) {
      return;
    }
    final start = _sessionStartMs ??= frame.timeMs;
    final draft = engine.add(frame, frame.timeMs - start);
    if (draft == null) return;
    _unsent.add(draft);
    _send();
  }

  /// Stores queued repetitions one at a time, in the order they were counted.
  void _send() {
    _sending ??= _drain().whenComplete(() => _sending = null);
  }

  Future<void> _drain() async {
    final session = _session;
    if (session == null) return;
    final repository = ref.read(patientRepositoryProvider);
    while (mounted && _unsent.isNotEmpty && _pause == null) {
      final draft = _unsent.first;
      try {
        final stored = await repository.recordRepetition(
          sessionId: session.id,
          repetition: draft,
        );
        if (!mounted) return;
        _unsent.remove(draft);
        setState(() {
          _lastStored = stored;
          _saveProblem = null;
          _tiers[(stored.setNumber, stored.repNumber)] = stored.tier;
          final pause = stored.pause;
          if (pause != null) {
            // Anything counted after the RED repetition happened while the
            // session was already paused on the server: it was never part of
            // it.
            _unsent.clear();
            _engine?.rewindTo(
              setNumber: stored.setNumber,
              repNumber: stored.repNumber,
            );
            _pause = pause;
            _pauseError = null;
            _understood = false;
          }
        });
      } on ApiException catch (error) {
        if (!mounted) return;
        if (error.code == ApiException.network.code) {
          // Kept in the queue and sent again with the same key, so it is
          // stored once however many times it takes.
          setState(
            () => _saveProblem =
                'Your last repetition is not saved yet. Trying again…',
          );
          _retry?.cancel();
          _retry = Timer(const Duration(seconds: 2), _send);
        } else if (error.code == 'session_paused') {
          await _matchServer();
        } else {
          _unsent.clear();
          setState(() {
            _saveProblem = null;
            _stopped = error.message;
          });
        }
        return;
      }
    }
  }

  /// Brings the screen in line with the session as the server holds it.
  Future<void> _matchServer() async {
    final session = _session;
    if (session == null) return;
    try {
      final current = await ref
          .read(patientRepositoryProvider)
          .session(session.id);
      if (!mounted) return;
      _unsent.clear();
      _engine?.rewindToCount(current.totals.repetitions);
      setState(() {
        if (current.pause != null && _pause == null) _understood = false;
        _pause = current.pause;
        if (current.status != 'active' && current.status != 'paused') {
          _stopped = 'This session has already ended.';
        }
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _stopped = error.message);
    }
  }

  Future<void> _acknowledge() async {
    final session = _session;
    final pause = _pause;
    if (session == null || pause == null || _acknowledging) return;
    setState(() {
      _acknowledging = true;
      _pauseError = null;
    });
    try {
      await ref
          .read(patientRepositoryProvider)
          .acknowledgePause(
            sessionId: session.id,
            repetitionId: pause.repetitionId,
          );
      if (!mounted) return;
      // The next repetition is counted from the resting position, not from
      // wherever the patient happens to be standing when they press the button.
      _engine?.interrupt();
      setState(() {
        _pause = null;
        _acknowledging = false;
        _understood = false;
        _lastStored = null;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _acknowledging = false;
        _pauseError = error.message;
      });
    }
  }

  void _leave() => context.go('/patient/plan');

  Future<void> _end() async {
    final session = _session;
    if (session == null || _ending) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End this session?'),
        content: const Text(
          'Your session will be saved with what you have done so far.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep going'),
          ),
          FilledButton(
            key: const Key('confirm-end-session'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('End session'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _ending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // A repetition on its way to the server is let through first, so the
      // summary counts it.
      _retry?.cancel();
      _send();
      await _sending;
      if (!mounted) return;
      await _savePainBefore();
      if (!mounted) return;
      final ended = await ref
          .read(patientRepositoryProvider)
          .endSession(session.id);
      _clock?.cancel();
      _retry?.cancel();
      // The camera is not needed for the summary, so it goes off now rather
      // than when the screen closes.
      unawaited(_frames?.cancel());
      unawaited(_source.stop());
      if (!mounted) return;
      setState(() {
        _ending = false;
        _finished = ended;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _ending = false);
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  static String _minutes(Duration time) {
    final minutes = time.inMinutes;
    final seconds = time.inSeconds % 60;
    if (minutes == 0) return seconds == 1 ? '1 second' : '$seconds seconds';
    return '$minutes min ${seconds.toString().padLeft(2, '0')} s';
  }

  static String _clockText(Duration time) =>
      '${time.inMinutes.toString().padLeft(2, '0')}:'
      '${(time.inSeconds % 60).toString().padLeft(2, '0')}';

  HoloExercise _holoExercise(PrecheckRequirements requirements) =>
      HoloExercise.of(requirements.exercise.slug, requirements.exercise.name);

  @override
  Widget build(BuildContext context) {
    final requirements = ref.watch(precheckRequirementsProvider(widget.itemId));
    final narrow = MediaQuery.sizeOf(context).width < 600;

    return Scaffold(
      backgroundColor: AppColors.navyDeep,
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: AppColors.sessionGradient),
        child: Stack(
          children: [
            // Soft coloured light in the corners of the room.
            const Positioned(
              left: -160,
              top: -160,
              child: _Glow(color: AppColors.primaryMint, size: 420),
            ),
            const Positioned(
              right: -200,
              bottom: -220,
              child: _Glow(color: Color(0xFF5C6BC0), size: 520),
            ),
            SafeArea(
              child: Column(
                children: [
                  _topBar(requirements.valueOrNull, narrow),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        narrow ? 12 : 32,
                        narrow ? 8 : 16,
                        narrow ? 12 : 32,
                        32,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1280),
                          child: AsyncSection(
                            value: requirements,
                            onRetry: () => ref.invalidate(
                              precheckRequirementsProvider(widget.itemId),
                            ),
                            builder: _content,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Floating bar over the room: the way out, the exercise, the status.
  Widget _topBar(PrecheckRequirements? requirements, bool narrow) {
    final finished = _finished != null;
    final live = _session != null && !finished;
    final onLeave = _ending ? null : (live ? _end : _leave);
    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? 8 : 28, 10, narrow ? 8 : 28, 6),
      child: Row(
        children: [
          live
              ? OutlinedButton.icon(
                  key: const Key('session-back'),
                  // Once a session is running, leaving means ending it.
                  onPressed: onLeave,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 42),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    foregroundColor: const Color(0xFFFF8A80),
                    side: const BorderSide(
                      color: Color(0xFFFF8A80),
                      width: 1.5,
                    ),
                  ),
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text('End'),
                )
              : TextButton.icon(
                  key: const Key('session-back'),
                  onPressed: onLeave,
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  icon: const Icon(Icons.arrow_back_rounded, size: 18),
                  label: const Text('My plan'),
                ),
          const SizedBox(width: 16),
          Expanded(
            child: requirements == null || finished
                ? const SizedBox.shrink()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        requirements.exercise.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.headingMedium.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${requirements.sets} sets × ${requirements.reps} reps  ·  '
                        '${requirements.restSeconds == 0 ? 'no rest' : '${requirements.restSeconds}s rest'}  ·  '
                        '${requirements.difficulty.label}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.bodyMedium.copyWith(
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
          ),
          const SizedBox(width: 12),
          if (finished)
            const Pill.success('Session complete', icon: Icons.check_rounded)
          else if (live && _pause != null)
            const Pill(
              'Session paused',
              foreground: Colors.white,
              background: AppColors.severityRed,
              icon: Icons.pause_rounded,
            )
          else if (live)
            const Pill(
              'Session in progress',
              foreground: AppColors.primaryMint,
              background: Color(0x2600BFA5),
              icon: Icons.circle,
            )
          else
            Pill(
              'Camera check',
              foreground: Colors.white.withValues(alpha: 0.85),
              background: Colors.white.withValues(alpha: 0.1),
              icon: Icons.videocam_outlined,
            ),
        ],
      ),
    );
  }

  Widget _content(PrecheckRequirements requirements) {
    final problem = _cameraProblem;
    final finished = _finished;
    if (finished != null) return _summary(requirements, finished);
    final pause = _pause;
    if (problem != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(
                  height: 180,
                  child: HoloStage(
                    child: HoloFigure(
                      tone: HoloTone.neutral,
                      semanticLabel: 'PhysioAI guide',
                    ),
                  ),
                ),
                EmptyState(
                  key: const Key('camera-problem'),
                  icon: Icons.videocam_off_outlined,
                  message: '${problem.title}\n\n${problem.help}',
                  action: problem.problem == CameraProblem.unsupported
                      ? SecondaryButton(
                          onPressed: _leave,
                          label: 'Back to my plan',
                        )
                      : FilledButton(
                          key: const Key('camera-retry'),
                          onPressed: _startCamera,
                          child: const Text('Try again'),
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return ResponsiveRow(
      breakpoint: 900,
      flex: const [3, 2],
      children: [
        _camera(requirements),
        if (_session == null)
          _setup(requirements)
        else if (pause != null)
          _paused(requirements, pause)
        else
          _live(requirements),
      ],
    );
  }

  /// The camera picture, framed like a stage, with the tracked body and the
  /// heads-up display drawn over it.
  Widget _camera(PrecheckRequirements requirements) {
    final live = _session != null;
    final paused = _pause != null;
    final inView = _reading?.ok ?? !live;
    final holding = !live && (_reading?.ok ?? false);
    final frameColor = paused
        ? AppColors.severityRed
        : live && !inView
        ? const Color(0xFFFFA726)
        : live || holding
        ? AppColors.primaryMint
        : AppColors.navyLight;
    final stored = _lastStored;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: frameColor.withValues(alpha: 0.75), width: 2),
        boxShadow: [
          BoxShadow(
            color: frameColor.withValues(alpha: 0.28),
            blurRadius: 32,
            spreadRadius: -2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: AspectRatio(
          aspectRatio: _source.aspectRatio,
          child: ColoredBox(
            color: AppColors.navyDeep,
            child: !_cameraOn
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      const HoloStage(
                        dark: true,
                        radius: 0,
                        child: HoloFigure(tone: HoloTone.neutral),
                      ),
                      Align(
                        alignment: const Alignment(0, 0.9),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'Starting your camera…',
                              style: AppTheme.bodyLarge.copyWith(
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      _source.preview(),
                      // Darken the lower half so the display stays readable.
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0x330D1F2D),
                              Color(0x000D1F2D),
                              Color(0x000D1F2D),
                              Color(0xB30D1F2D),
                            ],
                            stops: [0, 0.2, 0.5, 1],
                          ),
                        ),
                      ),
                      if (!live) _GhostGuide(found: _reading?.bodyOk ?? false),
                      if (_frame != null)
                        CustomPaint(
                          key: const Key('pose-overlay'),
                          painter: _SkeletonPainter(
                            frame: _frame!,
                            required: requirements.requiredLandmarks.toSet(),
                            minVisibility: requirements.minVisibility,
                            color: paused
                                ? const Color(0xFFFF6E6E)
                                : live && !inView
                                ? const Color(0xFFFFB74D)
                                : AppColors.primaryMint,
                          ),
                        ),
                      Positioned(
                        left: 14,
                        top: 14,
                        right: 14,
                        child: Row(
                          children: [
                            if (live) ...[
                              _HudChip(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _LiveDot(paused: paused),
                                    const SizedBox(width: 8),
                                    Text(
                                      _clockText(_elapsed),
                                      key: const Key('session-timer'),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 20,
                                        fontWeight: FontWeight.w700,
                                        height: 1,
                                        fontFeatures: [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ] else
                              _HudChip(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.center_focus_strong_rounded,
                                      size: 16,
                                      color: holding
                                          ? AppColors.primaryMint
                                          : Colors.white70,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      holding ? 'Hold still' : 'Find your spot',
                                      style: AppTheme.labelBold.copyWith(
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            const Spacer(),
                            _HudChip(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.accessibility_new_rounded,
                                    size: 16,
                                    color: _frame?.landmarks.isNotEmpty ?? false
                                        ? AppColors.primaryMint
                                        : Colors.white54,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _frame?.landmarks.isNotEmpty ?? false
                                        ? 'AI tracking'
                                        : 'Searching',
                                    style: AppTheme.labelBold.copyWith(
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (live &&
                          !paused &&
                          stored != null &&
                          (stored.tier == FeedbackTier.amber ||
                              stored.tier == FeedbackTier.info))
                        Positioned(
                          left: 14,
                          right: 14,
                          bottom: 14,
                          child: _CameraToast(
                            key: ValueKey(stored.id),
                            tier: stored.tier,
                            exercise: _holoExercise(requirements),
                            fault: HoloFault.fromCheck(
                              stored.feedback.isEmpty
                                  ? null
                                  : stored.feedback.first.check,
                            ),
                            message: stored.feedback.isEmpty
                                ? null
                                : stored.feedback.first.message,
                          ),
                        ),
                      if (paused)
                        _PauseVeil(
                          exercise: _holoExercise(requirements),
                          fault: HoloFault.fromCheck(_pause!.check),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _setup(PrecheckRequirements requirements) {
    final text = Theme.of(context).textTheme;
    final reading = _reading;
    final tracker = _tracker;
    final holding = reading?.ok ?? false;
    final ready = _starting || holding;
    return _Panel(
      children: [
        Row(
          children: [
            SizedBox(
              width: 92,
              height: 112,
              child: HoloStage(
                radius: 16,
                child: HoloFigure(
                  exercise: _holoExercise(requirements),
                  pedestal: true,
                  guides: false,
                  semanticLabel: 'How the movement looks',
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ready ? 'All set!' : 'Getting ready…',
                    style: AppTheme.headingLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Prop your device up, step back, and let the camera see you. '
                    'Your session starts by itself when everything is ready.',
                    style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _Check(
          key: const Key('check-camera'),
          label: 'Camera on',
          state: _cameraOn,
          icon: Icons.videocam_outlined,
        ),
        _Check(
          key: const Key('check-lighting'),
          label: 'Enough light',
          state: reading?.lightingOk,
          icon: Icons.light_mode_outlined,
        ),
        _Check(
          key: const Key('check-body'),
          label: 'Body in view: ${_parts(requirements.requiredLandmarks)}',
          state: reading == null ? null : reading.lightingOk && reading.bodyOk,
          icon: Icons.accessibility_new_rounded,
        ),
        const SizedBox(height: 16),
        if (_startError != null) ...[
          InlineBanner(key: const Key('session-error'), message: _startError!),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const Key('retry-start'),
              onPressed: _retryStart,
              child: const Text('Try again'),
            ),
          ),
        ] else if (_starting)
          const InlineBanner(
            key: Key('setup-guidance'),
            tone: BannerTone.success,
            message: 'All set. Starting your session…',
          )
        else if (holding) ...[
          const InlineBanner(
            key: Key('setup-guidance'),
            tone: BannerTone.success,
            message: 'Looking good. Hold that position…',
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              key: const Key('hold-progress'),
              value: tracker?.progress ?? 0,
              minHeight: 6,
              color: AppColors.severityGreen,
              backgroundColor: AppColors.divider,
            ),
          ),
        ] else
          InlineBanner(
            key: const Key('setup-guidance'),
            tone: BannerTone.info,
            icon: Icons.accessibility_new_rounded,
            message:
                reading?.guidance ??
                (_cameraOn
                    ? 'Looking for you…'
                    : 'Allow the camera when your browser asks.'),
          ),
        const SizedBox(height: 16),
        Text('Any pain right now?', style: text.titleSmall),
        Text(
          'Optional. Your session starts either way.',
          style: text.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        PainScale(
          name: 'pain-before',
          value: _painBefore,
          onChanged: (value) => setState(() => _painBefore = value),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.lock_outline_rounded,
              size: 16,
              color: AppColors.textHint,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'The video stays on this device. Only the positions of your joints are used.',
                style: text.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _live(PrecheckRequirements requirements) {
    final text = Theme.of(context).textTheme;
    final reading = _reading;
    final inView = reading?.ok ?? true;
    final engine = _engine;
    final counting = engine != null && engine.canCount;
    final done = engine?.prescriptionDone ?? false;
    final stored = _lastStored;
    final stacked = MediaQuery.sizeOf(context).width < 960;
    return _Panel(
      handle: stacked,
      children: [
        if (counting) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      PopOnChange(
                        value: engine.counted,
                        child: Text(
                          '${done ? requirements.reps : engine.repsInSet}',
                          key: const Key('rep-count'),
                          style: const TextStyle(
                            fontSize: 64,
                            height: 1,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary,
                            letterSpacing: -2,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      Text(
                        '/${requirements.reps}',
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textHint,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'REPS',
                    style: AppTheme.labelBold.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Set ${done ? requirements.sets : engine.currentSet} of ${requirements.sets}',
                    key: const Key('set-progress'),
                    style: text.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  _SetPills(
                    sets: requirements.sets,
                    current: done ? requirements.sets + 1 : engine.currentSet,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          _RepDots(
            reps: requirements.reps,
            tiers: [
              for (var rep = 1; rep <= requirements.reps; rep++)
                _tiers[(done ? requirements.sets : engine.currentSet, rep)],
            ],
            current: done ? null : engine.repsInSet + 1,
          ),
          const SizedBox(height: 16),
          if (done)
            const InlineBanner(
              key: Key('prescription-done'),
              tone: BannerTone.success,
              icon: Icons.emoji_events_outlined,
              message:
                  'You have done every set. End the session when you are ready.',
            )
          else if (stored != null)
            _feedback(requirements, stored)
          else
            const InlineBanner(
              key: Key('rep-feedback'),
              tone: BannerTone.info,
              icon: Icons.accessibility_new_rounded,
              message:
                  'Start when you are ready. Each repetition is counted for you.',
            ),
        ] else ...[
          Text('Follow the guide', style: AppTheme.headingLarge),
          const SizedBox(height: 4),
          Text(
            'Move with the hologram at your own pace.',
            style: text.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
        const SizedBox(height: 12),
        InlineBanner(
          key: const Key('tracking-status'),
          tone: inView ? BannerTone.success : BannerTone.warning,
          icon: inView
              ? Icons.check_circle_outline_rounded
              : Icons.accessibility_new_rounded,
          message: inView
              ? 'Tracking your movement.'
              : reading?.guidance ?? 'Step back into view.',
        ),
        if (_saveProblem != null) ...[
          const SizedBox(height: 12),
          InlineBanner(
            key: const Key('save-problem'),
            tone: BannerTone.warning,
            icon: Icons.cloud_off_rounded,
            message: _saveProblem!,
          ),
        ],
        if (_stopped != null) ...[
          const SizedBox(height: 12),
          InlineBanner(key: const Key('session-stopped'), message: _stopped!),
        ],
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: counting ? 84 : 120,
                height: counting ? 104 : 150,
                child: HoloStage(
                  radius: 14,
                  child: HoloFigure(
                    exercise: _holoExercise(requirements),
                    guides: false,
                    semanticLabel: 'How the movement looks',
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'HOW TO MOVE',
                      style: AppTheme.labelBold.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      requirements.exercise.instructions,
                      style: text.bodySmall?.copyWith(color: AppColors.text),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!counting) ...[
          const SizedBox(height: 12),
          Text(
            'Repetitions are not counted for this exercise yet. '
            'This session records the time you exercised.',
            key: const Key('counting-unavailable'),
            style: text.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
        const SizedBox(height: 20),
        BusyButton(
          key: const Key('end-session'),
          label: 'End Session',
          icon: Icons.flag_rounded,
          busy: _ending,
          onPressed: _end,
        ),
      ],
    );
  }

  /// What the server found in the last repetition. INFO and AMBER are shown
  /// here and the session carries on; RED never reaches this slot, because
  /// it pauses the session instead.
  Widget _feedback(
    PrecheckRequirements requirements,
    RecordedRepetition stored,
  ) {
    final worst = stored.feedback.isEmpty ? null : stored.feedback.first;
    final exercise = _holoExercise(requirements);
    final fault = HoloFault.fromCheck(worst?.check);
    final Widget card = switch (stored.tier) {
      FeedbackTier.amber => _AmberFeedback(
        key: Key('rep-feedback-${stored.tier.name}'),
        exercise: exercise,
        fault: fault,
        message: worst?.message ?? 'Check your form on the next one.',
      ),
      FeedbackTier.info => _InfoFeedback(
        key: Key('rep-feedback-${stored.tier.name}'),
        exercise: exercise,
        fault: fault,
        message: worst?.message ?? 'A small thing to refine.',
      ),
      _ => InlineBanner(
        key: Key('rep-feedback-${stored.tier.name}'),
        tone: BannerTone.success,
        icon: Icons.check_circle_outline_rounded,
        message: 'Good repetition.',
      ),
    };
    return Semantics(
      liveRegion: true,
      child: SlideUpIn(key: ValueKey(stored.id), child: card),
    );
  }

  /// The safety pause: a RED repetition stops everything until the patient
  /// has read what to change and confirmed they understand.
  Widget _paused(PrecheckRequirements requirements, SessionPause pause) {
    final text = Theme.of(context).textTheme;
    final exercise = _holoExercise(requirements);
    final fault = HoloFault.fromCheck(pause.check);
    final title = fault == HoloFault.none
        ? pause.check.replaceAll('_', ' ')
        : fault.title;
    return _Panel(
      key: const Key('safety-pause'),
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.severityRed,
                borderRadius: BorderRadius.circular(100),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.severityRed.withValues(alpha: 0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.pause_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Session paused',
                    style: AppTheme.labelBold.copyWith(color: Colors.white),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text('Serious form error', style: AppTheme.headingLarge),
        const SizedBox(height: 14),
        Semantics(
          liveRegion: true,
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
              border: Border.all(
                color: AppColors.severityRed.withValues(alpha: 0.18),
              ),
              boxShadow: AppTheme.cardShadow,
            ),
            clipBehavior: Clip.antiAlias,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(
                  left: BorderSide(color: AppColors.severityRed, width: 4),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppTheme.paddingM),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.toUpperCase(),
                      style: AppTheme.labelBold.copyWith(
                        color: AppColors.severityRed,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      pause.message,
                      key: const Key('pause-message'),
                      style: AppTheme.bodyLarge.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 210,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _Shake(
                  child: _CompareBox(
                    severity: Severity.red,
                    label: 'Incorrect',
                    icon: Icons.close_rounded,
                    figure: HoloFigure(
                      exercise: exercise,
                      fault: fault,
                      tone: HoloTone.red,
                      mark: HoloMark.cross,
                      turn: 12,
                      semanticLabel: 'The movement as it was done',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CompareBox(
                  severity: Severity.good,
                  label: 'Correct',
                  icon: Icons.check_rounded,
                  figure: HoloFigure(
                    exercise: exercise,
                    fault: fault,
                    correctVersion: true,
                    tone: HoloTone.correct,
                    mark: HoloMark.tick,
                    turn: 12,
                    semanticLabel: 'The movement done safely',
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'That last repetition could put strain on your body, so nothing '
          'is being counted. Read the message, get back into position, and '
          'continue only if it feels comfortable. If anything hurts, stop '
          'and speak to your physiotherapist.',
          style: text.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        if (_pauseError != null) ...[
          const SizedBox(height: 12),
          InlineBanner(key: const Key('pause-error'), message: _pauseError!),
        ],
        const SizedBox(height: 14),
        _Understood(
          key: const Key('pause-understood'),
          value: _understood,
          onChanged: _acknowledging
              ? null
              : (value) => setState(() => _understood = value),
        ),
        const SizedBox(height: 14),
        BusyButton(
          key: const Key('acknowledge-pause'),
          label: 'Resume Session',
          icon: Icons.play_arrow_rounded,
          busy: _acknowledging,
          onPressed: _understood ? _acknowledge : null,
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('end-session'),
          onPressed: _ending || _acknowledging ? null : _end,
          child: const Text('End session instead'),
        ),
      ],
    );
  }

  /// What the session came to, read from what the server stored.
  Widget _summary(PrecheckRequirements requirements, ExerciseSession ended) {
    final text = Theme.of(context).textTheme;
    final summary = ended.summary;
    final totals = summary?.totals ?? ended.totals;
    final counted = _engine?.canCount ?? false;
    final score = summary?.formScore;
    final change = summary?.scoreChange;
    final engine = _engine;
    final setsDone = engine == null
        ? 0
        : engine.prescriptionDone
        ? requirements.sets
        : engine.currentSet - 1;
    final history = ref.watch(patientSessionsProvider).valueOrNull;
    final trend = <int>[
      for (final past in (history ?? const <SessionBrief>[]).reversed)
        if (past.exercise.id == requirements.exercise.id &&
            past.id != ended.id &&
            past.formScore != null)
          past.formScore!,
    ];
    final points = [
      ...trend.length > 4 ? trend.sublist(trend.length - 4) : trend,
      if (trend.isEmpty && summary?.previous?.formScore != null)
        summary!.previous!.formScore!,
      ?score,
    ];

    final String cheer;
    if (score == null) {
      cheer = 'Every session counts. Well done for showing up.';
    } else if (score > 85) {
      cheer = 'Excellent session!';
    } else if (score >= 70) {
      cheer = 'Great progress! Keep it up.';
    } else {
      cheer = "Keep practising. You're improving.";
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Container(
          key: const Key('session-summary'),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppTheme.radiusXL + 4),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 40,
                offset: Offset(0, 20),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                decoration: const BoxDecoration(
                  gradient: AppColors.cardGradient,
                ),
                child: Column(
                  children: [
                    const CelebrationCheck(size: 64),
                    const SizedBox(height: 8),
                    Text(
                      'Session complete',
                      textAlign: TextAlign.center,
                      style: AppTheme.headingLarge.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      requirements.exercise.name,
                      textAlign: TextAlign.center,
                      style: text.bodyLarge?.copyWith(color: Colors.white70),
                    ),
                    if (counted && summary != null) ...[
                      const SizedBox(height: 20),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 96,
                              height: 130,
                              child: HoloFigure(
                                exercise: _holoExercise(requirements),
                                tone: HoloTone.correct,
                                guides: false,
                              ),
                            ),
                            const SizedBox(width: 16),
                            ScoreBadge(
                              key: const Key('summary-score'),
                              score: summary.formScore,
                              size: 132,
                              onDark: true,
                              animate: true,
                            ),
                            const SizedBox(width: 112),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        summary.formScore == null
                            ? 'No form score: there was nothing to score.'
                            : 'Form score out of 100',
                        key: const Key('summary-score-label'),
                        textAlign: TextAlign.center,
                        style: text.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(100),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              change == null || change == 0
                                  ? Icons.insights_rounded
                                  : change > 0
                                  ? Icons.trending_up_rounded
                                  : Icons.trending_down_rounded,
                              size: 18,
                              color: AppColors.primaryMint,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                summary.trend,
                                key: const Key('summary-trend'),
                                textAlign: TextAlign.center,
                                style: text.bodyMedium?.copyWith(
                                  color: AppColors.primaryMint,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      cheer,
                      textAlign: TextAlign.center,
                      style: AppTheme.headingMedium,
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        if (counted) ...[
                          Expanded(
                            child: StatTile(
                              key: const Key('summary-repetitions'),
                              value: '${totals.repetitions}',
                              label: 'Total reps',
                              icon: Icons.repeat_rounded,
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: StatTile(
                            key: const Key('summary-time'),
                            value: summary == null
                                ? _minutes(_elapsed)
                                : formatDuration(summary.durationSeconds),
                            label: 'Duration',
                            icon: Icons.timer_outlined,
                            color: AppColors.navy,
                          ),
                        ),
                        if (counted) ...[
                          const SizedBox(width: 10),
                          Expanded(
                            child: StatTile(
                              value: '$setsDone/${requirements.sets}',
                              label: 'Sets completed',
                              icon: Icons.layers_outlined,
                              color: AppColors.severityGreen,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (counted) ...[
                      const SizedBox(height: 18),
                      PhysioCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Feedback summary',
                              style: AppTheme.headingSmall,
                            ),
                            const SizedBox(height: 8),
                            _SummaryRow(
                              key: const Key('summary-ok'),
                              label: 'Good form',
                              count: totals.ok,
                              total: totals.repetitions,
                              color: AppColors.severityGreen,
                            ),
                            _SummaryRow(
                              key: const Key('summary-info'),
                              label: 'Small things to refine',
                              count: totals.info,
                              total: totals.repetitions,
                              color: AppColors.severityInfo,
                            ),
                            _SummaryRow(
                              key: const Key('summary-amber'),
                              label: 'Form to work on',
                              count: totals.amber,
                              total: totals.repetitions,
                              color: AppColors.severityAmber,
                            ),
                            _SummaryRow(
                              key: const Key('summary-red'),
                              label: 'Paused for safety',
                              count: totals.red,
                              total: totals.repetitions,
                              color: AppColors.severityRed,
                            ),
                          ],
                        ),
                      ),
                      if (points.length >= 2) ...[
                        const SizedBox(height: 14),
                        PhysioCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Your last ${points.length} sessions',
                                style: AppTheme.headingSmall,
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                height: 70,
                                width: double.infinity,
                                child: CustomPaint(
                                  painter: _SparklinePainter(points),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 14),
                    PainAfterCard(sessionId: ended.id),
                    const SizedBox(height: 22),
                    PrimaryButton(
                      buttonKey: const Key('summary-done'),
                      label: 'Back to my plan',
                      trailingIcon: Icons.arrow_forward_rounded,
                      onPressed: _leave,
                      expand: true,
                    ),
                    const SizedBox(height: 10),
                    SecondaryButton(
                      label: 'View full details',
                      icon: Icons.history_rounded,
                      onPressed: () => context.go('/patient/history'),
                      expand: true,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// "shoulders, hips, knees and ankles" from the landmark names.
  static String _parts(List<String> landmarks) {
    const order = ['shoulder', 'elbow', 'wrist', 'hip', 'knee', 'ankle'];
    final parts = [
      for (final part in order)
        if (landmarks.any((name) => name.endsWith(part))) '${part}s',
    ];
    if (parts.length < 2) return parts.join();
    return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  }
}

/// The white control panel beside (or under) the camera.
class _Panel extends StatelessWidget {
  const _Panel({super.key, required this.children, this.handle = false});

  final List<Widget> children;
  final bool handle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 30,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (handle) ...[
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 14),
          ] else
            const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}

class _HudChip extends StatelessWidget {
  const _HudChip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(100),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0x800D1F2D),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _LiveDot extends StatelessWidget {
  const _LiveDot({required this.paused});

  final bool paused;

  @override
  Widget build(BuildContext context) {
    final color = paused ? const Color(0xFFFFB74D) : const Color(0xFFFF5252);
    return Pulse(
      scale: paused ? 1 : 1.35,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: color, blurRadius: 8)],
        ),
      ),
    );
  }
}

/// The ghost of a person standing where the patient should stand, shown
/// over the camera until they are found.
class _GhostGuide extends StatelessWidget {
  const _GhostGuide({required this.found});

  final bool found;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: found ? 0 : 1,
        duration: const Duration(milliseconds: 400),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final height = constraints.maxHeight * 0.82;
            return Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  top: constraints.maxHeight * 0.08,
                  child: SizedBox(
                    width: height * 0.6,
                    height: height,
                    child: CustomPaint(
                      painter: _DashedFramePainter(),
                      child: const Opacity(
                        opacity: 0.32,
                        child: HoloFigure(
                          tone: HoloTone.neutral,
                          pedestal: false,
                          guides: false,
                          turn: 0,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: constraints.maxHeight * 0.08 + 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(100),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.south_rounded,
                          size: 14,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Stand here',
                          style: AppTheme.labelBold.copyWith(
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DashedFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(28),
    );
    final path = Path()..addRRect(rect);
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 16) {
        canvas.drawPath(metric.extractPath(d, d + 9), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedFramePainter old) => false;
}

/// Over the camera while the session is paused: the picture blurs behind a
/// deep navy veil with a pulsing warning.
class _PauseVeil extends StatelessWidget {
  const _PauseVeil({required this.exercise, required this.fault});

  final HoloExercise exercise;
  final HoloFault fault;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: ColoredBox(
            color: const Color(0xF20A1423),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Pulse(
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.severityRed.withValues(
                              alpha: 0.12,
                            ),
                            border: Border.all(
                              color: AppColors.severityRed,
                              width: 3,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.severityRed.withValues(
                                  alpha: 0.5,
                                ),
                                blurRadius: 30,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.warning_rounded,
                            color: Color(0xFFFF5252),
                            size: 40,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Movement stopped',
                        style: AppTheme.headingLarge.copyWith(
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          'Return to your starting position and read the guidance.',
                          textAlign: TextAlign.center,
                          style: AppTheme.bodyMedium.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: HoloFigure(
                    exercise: exercise,
                    fault: fault,
                    tone: HoloTone.red,
                    mark: HoloMark.cross,
                    semanticLabel: 'What went wrong',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A short-lived card over the camera when AMBER or INFO feedback arrives,
/// big enough to read from across the room. It fades away by itself (4 s
/// for AMBER, 2.5 s for INFO); the panel keeps the message.
class _CameraToast extends StatefulWidget {
  const _CameraToast({
    super.key,
    required this.tier,
    required this.exercise,
    required this.fault,
    required this.message,
  });

  final FeedbackTier tier;
  final HoloExercise exercise;
  final HoloFault fault;
  final String? message;

  @override
  State<_CameraToast> createState() => _CameraToastState();
}

class _CameraToastState extends State<_CameraToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _life;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _life = AnimationController(
      vsync: this,
      duration: widget.tier == FeedbackTier.amber
          ? const Duration(milliseconds: 4000)
          : const Duration(milliseconds: 2500),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started && Motion.of(context)) {
      _started = true;
      _life.forward();
    }
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_started) return const SizedBox.shrink();
    final amber = widget.tier == FeedbackTier.amber;
    final severity = amber ? Severity.amber : Severity.info;
    return AnimatedBuilder(
      animation: _life,
      builder: (context, child) {
        final t = _life.value;
        if (t >= 1) return const SizedBox.shrink();
        final enter = Curves.easeOutCubic.transform((t / 0.08).clamp(0.0, 1.0));
        final exit = ((1 - t) / 0.1).clamp(0.0, 1.0);
        return Opacity(
          opacity: enter * exit,
          child: Transform.translate(
            offset: Offset(0, 30 * (1 - enter)),
            child: child,
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(18),
          border: Border(left: BorderSide(color: severity.color, width: 4)),
          boxShadow: const [
            BoxShadow(color: Color(0x40000000), blurRadius: 20),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    amber ? 'FORM CORRECTION' : 'TIP',
                    style: AppTheme.labelBold.copyWith(color: severity.color),
                  ),
                  if (widget.message != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      widget.message!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.headingSmall.copyWith(height: 1.3),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(
              width: 64,
              height: 72,
              child: HoloFigure(
                exercise: widget.exercise,
                fault: widget.fault,
                tone: amber ? HoloTone.amber : HoloTone.info,
                pedestal: false,
                turn: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// AMBER: a correction to make on the next repetition. The session carries
/// on.
class _AmberFeedback extends StatelessWidget {
  const _AmberFeedback({
    super.key,
    required this.exercise,
    required this.fault,
    required this.message,
  });

  final HoloExercise exercise;
  final HoloFault fault;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        border: Border.all(
          color: AppColors.severityAmber.withValues(alpha: 0.2),
        ),
        boxShadow: AppTheme.cardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(
            left: BorderSide(color: AppColors.severityAmber, width: 4),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: AppColors.severityAmber,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'FORM CORRECTION',
                          style: AppTheme.labelBold.copyWith(
                            color: AppColors.severityAmber,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.warning_amber_rounded,
                          size: 16,
                          color: AppColors.severityAmber,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      message,
                      style: AppTheme.bodyLarge.copyWith(
                        fontWeight: FontWeight.w500,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Session continuing…',
                      style: AppTheme.bodyMedium.copyWith(
                        color: AppColors.textHint,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 86,
                height: 104,
                child: HoloStage(
                  tint: AppColors.severityAmber,
                  radius: 14,
                  child: HoloFigure(
                    exercise: exercise,
                    fault: fault,
                    tone: HoloTone.amber,
                    turn: 12,
                    semanticLabel: 'The correction to make',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// INFO: a small thing to refine, kept compact.
class _InfoFeedback extends StatelessWidget {
  const _InfoFeedback({
    super.key,
    required this.exercise,
    required this.fault,
    required this.message,
  });

  final HoloExercise exercise;
  final HoloFault fault;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
      decoration: BoxDecoration(
        color: AppColors.severityInfoBg,
        borderRadius: BorderRadius.circular(40),
        border: Border.all(
          color: AppColors.severityInfo.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            height: 70,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: ColoredBox(
                color: Colors.white.withValues(alpha: 0.7),
                child: HoloFigure(
                  exercise: exercise,
                  fault: fault,
                  tone: HoloTone.info,
                  pedestal: false,
                  guides: false,
                  turn: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: AppColors.severityInfo,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTheme.bodyLarge.copyWith(
                color: AppColors.severityInfo,
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One side of the RED comparison: a tinted stage with its label.
class _CompareBox extends StatelessWidget {
  const _CompareBox({
    required this.severity,
    required this.label,
    required this.icon,
    required this.figure,
  });

  final Severity severity;
  final String label;
  final IconData icon;
  final Widget figure;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: severity.color.withValues(alpha: 0.35)),
      ),
      child: HoloStage(
        tint: severity.color,
        radius: 17,
        label: Align(
          alignment: Alignment.topLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: severity.color,
              borderRadius: BorderRadius.circular(100),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: Colors.white),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: AppTheme.labelBold.copyWith(
                    color: Colors.white,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
        ),
        child: Padding(padding: const EdgeInsets.only(top: 18), child: figure),
      ),
    );
  }
}

/// Shakes its child once when it first appears.
class _Shake extends StatelessWidget {
  const _Shake({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Motion.of(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 600),
      builder: (context, t, child) => Transform.translate(
        offset: Offset(math.sin(t * math.pi * 6) * 8 * (1 - t), 0),
        child: child,
      ),
      child: child,
    );
  }
}

/// "I understand and will correct my form", required before resuming.
class _Understood extends StatelessWidget {
  const _Understood({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: value,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: value ? AppColors.primaryTint : AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
            border: Border.all(
              color: value ? AppColors.primary : AppColors.border,
            ),
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: value ? AppColors.primary : AppColors.surface,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: value ? AppColors.primary : AppColors.border,
                    width: 2,
                  ),
                ),
                child: value
                    ? const Icon(
                        Icons.check_rounded,
                        size: 16,
                        color: Colors.white,
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'I understand and will correct my form',
                  style: AppTheme.bodyLarge,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One pill per set: done (green tick), current (teal), to come (outline).
class _SetPills extends StatelessWidget {
  const _SetPills({required this.sets, required this.current});

  final int sets;

  /// The set under way, from 1; above [sets] once all are done.
  final int current;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var set = 1; set <= sets; set++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            height: 28,
            constraints: const BoxConstraints(minWidth: 36),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: set < current
                  ? AppColors.severityGreen
                  : set == current
                  ? AppColors.primary
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(100),
              border: Border.all(
                color: set < current
                    ? AppColors.severityGreen
                    : set == current
                    ? AppColors.primary
                    : AppColors.border,
                width: 1.5,
              ),
            ),
            child: set < current
                ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                : Text(
                    'S$set',
                    style: AppTheme.labelBold.copyWith(
                      color: set == current
                          ? Colors.white
                          : AppColors.textMuted,
                      letterSpacing: 0.2,
                    ),
                  ),
          ),
      ],
    );
  }
}

/// A dot for each repetition of the set, coloured by how it went.
class _RepDots extends StatelessWidget {
  const _RepDots({
    required this.reps,
    required this.tiers,
    required this.current,
  });

  final int reps;
  final List<FeedbackTier?> tiers;

  /// The repetition under way, from 1; null when the prescription is done.
  final int? current;

  static Color _color(FeedbackTier? tier) => switch (tier) {
    FeedbackTier.ok => AppColors.severityGreen,
    FeedbackTier.info => AppColors.severityInfo,
    FeedbackTier.amber => AppColors.severityAmber,
    FeedbackTier.red => AppColors.severityRed,
    null => AppColors.border,
  };

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < reps; i++)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 16,
                height: 16,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: current == i + 1
                        ? AppColors.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _color(tiers[i]),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    super.key,
    required this.label,
    required this.count,
    required this.total,
    required this.color,
  });

  final String label;
  final int count;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 5,
            child: Text(label, style: AppTheme.bodyLarge.copyWith(height: 1.3)),
          ),
          Expanded(
            flex: 3,
            child: ProgressTrack(
              value: total == 0 ? 0 : count / total,
              color: color,
            ),
          ),
          SizedBox(
            width: 36,
            child: Text(
              '$count',
              textAlign: TextAlign.right,
              style: AppTheme.headingSmall.copyWith(
                color: count == 0 ? AppColors.textHint : color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Form scores of the last few sessions, this one highlighted.
class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.points);

  final List<int> points;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(12),
    );
    canvas.drawRRect(bg, Paint()..color = AppColors.surfaceAlt);
    if (points.length < 2) return;
    const pad = 14.0;
    Offset at(int i) => Offset(
      pad + (size.width - pad * 2) * i / (points.length - 1),
      size.height - pad - (size.height - pad * 2) * points[i] / 100,
    );
    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      final a = at(i - 1);
      final b = at(i);
      final mid = (a.dx + b.dx) / 2;
      path.cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
    }
    final fill = Path.from(path)
      ..lineTo(at(points.length - 1).dx, size.height - pad)
      ..lineTo(at(0).dx, size.height - pad)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = ui.Gradient.linear(Offset(0, pad), Offset(0, size.height), [
          AppColors.primaryMint.withValues(alpha: 0.25),
          AppColors.primaryMint.withValues(alpha: 0),
        ]),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
    for (var i = 0; i < points.length; i++) {
      final last = i == points.length - 1;
      if (last) {
        canvas.drawCircle(
          at(i),
          9,
          Paint()..color = AppColors.primaryMint.withValues(alpha: 0.25),
        );
      }
      canvas.drawCircle(at(i), last ? 6 : 3.5, Paint()..color = Colors.white);
      canvas.drawCircle(
        at(i),
        last ? 6 : 3.5,
        Paint()
          ..color = AppColors.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => old.points != points;
}

class _Check extends StatelessWidget {
  const _Check({
    super.key,
    required this.label,
    required this.state,
    required this.icon,
  });

  final String label;

  /// True when met, false when not, null while not known yet.
  final bool? state;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final (color, background, chip, meaning) = switch (state) {
      true => (
        AppColors.severityGreen,
        AppColors.severityGreenBg,
        'Passed',
        'done',
      ),
      false => (
        AppColors.severityAmber,
        AppColors.severityAmberBg,
        'Not yet',
        'not yet',
      ),
      null => (
        AppColors.textHint,
        AppColors.surfaceAlt,
        'Checking',
        'checking',
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: state == true
              ? AppColors.severityGreenBg.withValues(alpha: 0.5)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(
            color: state == true
                ? AppColors.severityGreen.withValues(alpha: 0.3)
                : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            AnimatedSwitcher(
              duration: Motion.checkDraw,
              transitionBuilder: (child, animation) =>
                  ScaleTransition(scale: animation, child: child),
              child: Container(
                key: ValueKey(state),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: state == true ? color : background,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  state == true ? Icons.check_rounded : icon,
                  size: 18,
                  color: state == true ? Colors.white : color,
                  semanticLabel: meaning,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(100),
              ),
              child: Text(
                chip,
                style: AppTheme.labelBold.copyWith(
                  color: color,
                  fontSize: 11,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws the tracked body over the camera picture as a glowing hologram
/// skeleton, so the patient can see what the app sees. The joints the
/// exercise relies on are larger and brighter; joints the model is unsure of
/// are faint.
class _SkeletonPainter extends CustomPainter {
  _SkeletonPainter({
    required this.frame,
    required this.required,
    required this.minVisibility,
    required this.color,
  });

  final PoseFrame frame;
  final Set<String> required;
  final double minVisibility;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    Offset? at(String name, [double threshold = 1]) {
      final point = frame.landmarks[name];
      if (point == null || point.visibility < minVisibility * threshold) {
        return null;
      }
      return Offset(point.x * size.width, point.y * size.height);
    }

    final glow = Paint()
      ..color = color.withValues(alpha: 0.45)
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    final core = Paint()
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    for (final (from, to) in poseBones) {
      final a = at(from);
      final b = at(to);
      if (a == null || b == null) continue;
      canvas.drawLine(a, b, glow);
      core.shader = ui.Gradient.linear(a, b, [
        Colors.white,
        Color.lerp(Colors.white, color, 0.6)!,
      ]);
      canvas.drawLine(a, b, core);
    }

    // The head, as a ring around the nose sized from the shoulders.
    final nose = at('nose');
    final ls = at('left_shoulder');
    final rs = at('right_shoulder');
    if (nose != null && ls != null && rs != null) {
      final radius = (ls - rs).distance * 0.32;
      canvas.drawCircle(
        nose,
        radius,
        Paint()
          ..color = color.withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      canvas.drawCircle(
        nose,
        radius,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }

    for (final name in poseLandmarkNames) {
      if (required.contains(name)) continue;
      final faint = at(name, 0.5);
      if (faint == null) continue;
      final sure = at(name) != null;
      canvas.drawCircle(
        faint,
        sure ? 3.5 : 2.5,
        Paint()..color = Colors.white.withValues(alpha: sure ? 0.7 : 0.3),
      );
    }
    for (final name in required) {
      final point = at(name);
      if (point == null) {
        final faint = at(name, 0.5);
        if (faint != null) {
          canvas.drawCircle(
            faint,
            6,
            Paint()
              ..color = color.withValues(alpha: 0.5)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5,
          );
        }
        continue;
      }
      canvas.drawCircle(
        point,
        13,
        Paint()
          ..color = color.withValues(alpha: 0.45)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawCircle(point, 8, Paint()..color = Colors.white);
      canvas.drawCircle(point, 5.5, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_SkeletonPainter old) =>
      old.frame != frame || old.color != color;
}
