import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../patient/patient_repository.dart';
import '../shell/page_widgets.dart';
import 'live_session.dart';
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
  late final PoseSource _source = ref.read(poseSourceProvider);
  StreamSubscription<PoseFrame>? _frames;
  ProviderSubscription<AsyncValue<PrecheckRequirements>>? _requirements;
  Timer? _clock;

  PrecheckTracker? _tracker;
  PoseFrame? _frame;
  SetupReading? _reading;
  CameraException? _cameraProblem;
  bool _cameraOn = false;

  ExerciseSession? _session;
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

  /// The session once it has ended, for the summary.
  ExerciseSession? _finished;

  @override
  void initState() {
    super.initState();
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

  @override
  Widget build(BuildContext context) {
    final requirements = ref.watch(precheckRequirementsProvider(widget.itemId));
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final finished = _finished != null;
    final live = _session != null && !finished;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 64,
              padding: EdgeInsets.symmetric(horizontal: narrow ? 8 : 32),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(bottom: BorderSide(color: AppColors.divider)),
              ),
              child: Row(
                children: [
                  TextButton.icon(
                    key: const Key('session-back'),
                    // Once a session is running, leaving means ending it.
                    onPressed: _ending ? null : (live ? _end : _leave),
                    icon: const Icon(Icons.arrow_back_rounded, size: 18),
                    label: const Text('My plan'),
                  ),
                  const Spacer(),
                  if (finished)
                    const Pill.success('Session complete')
                  else if (live && _pause != null)
                    const Pill.warning('Session paused')
                  else if (live)
                    const Pill.success('Session in progress')
                  else
                    const Pill.neutral('Camera check'),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(narrow ? 16 : 32),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1200),
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
    );
  }

  Widget _content(PrecheckRequirements requirements) {
    final text = Theme.of(context).textTheme;
    final problem = _cameraProblem;
    final finished = _finished;
    if (finished != null) return _summary(requirements, finished);
    final pause = _pause;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(requirements.exercise.name, style: text.headlineSmall),
        const SizedBox(height: 4),
        Text(
          '${requirements.sets} sets × ${requirements.reps} reps  ·  '
          '${requirements.restSeconds == 0 ? 'no rest' : '${requirements.restSeconds}s rest'}  ·  '
          '${requirements.difficulty.label}',
          style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: 24),
        if (problem != null)
          AppCard(
            child: EmptyState(
              key: const Key('camera-problem'),
              icon: Icons.videocam_off_outlined,
              message: '${problem.title}\n\n${problem.help}',
              action: problem.problem == CameraProblem.unsupported
                  ? OutlinedButton(
                      onPressed: _leave,
                      child: const Text('Back to my plan'),
                    )
                  : FilledButton(
                      key: const Key('camera-retry'),
                      onPressed: _startCamera,
                      child: const Text('Try again'),
                    ),
            ),
          )
        else
          ResponsiveRow(
            breakpoint: 900,
            flex: const [3, 2],
            children: [
              _camera(requirements),
              if (_session == null)
                _setup(requirements)
              else if (pause != null)
                _paused(pause)
              else
                _live(requirements),
            ],
          ),
      ],
    );
  }

  Widget _camera(PrecheckRequirements requirements) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: _source.aspectRatio,
        child: ColoredBox(
          color: AppColors.text,
          child: !_cameraOn
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.white),
                      SizedBox(height: 16),
                      Text(
                        'Starting your camera…',
                        style: TextStyle(color: Colors.white, fontSize: 15),
                      ),
                    ],
                  ),
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    _source.preview(),
                    if (_frame != null)
                      CustomPaint(
                        key: const Key('pose-overlay'),
                        painter: _SkeletonPainter(
                          frame: _frame!,
                          required: requirements.requiredLandmarks.toSet(),
                          minVisibility: requirements.minVisibility,
                        ),
                      ),
                  ],
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
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Get set up', style: text.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Prop your device up, step back, and let the camera see you. '
            'Your session starts by itself when everything is ready.',
            style: text.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: 16),
          _Check(
            key: const Key('check-camera'),
            label: 'Camera on',
            state: _cameraOn,
          ),
          _Check(
            key: const Key('check-lighting'),
            label: 'Enough light',
            state: reading?.lightingOk,
          ),
          _Check(
            key: const Key('check-body'),
            label: 'Body in view: ${_parts(requirements.requiredLandmarks)}',
            state: reading == null
                ? null
                : reading.lightingOk && reading.bodyOk,
          ),
          const SizedBox(height: 16),
          if (_startError != null) ...[
            InlineBanner(
              key: const Key('session-error'),
              message: _startError!,
            ),
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
          Text(
            'The video stays on this device. Only the positions of your joints are used.',
            style: text.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
      ),
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
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (counting) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${done ? requirements.reps : engine.repsInSet}',
                  key: const Key('rep-count'),
                  style: const TextStyle(
                    fontSize: 72,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 6, bottom: 8),
                  child: Text(
                    '/ ${requirements.reps}',
                    style: text.titleLarge?.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
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
                    const SizedBox(height: 4),
                    Text(
                      _clockText(_elapsed),
                      key: const Key('session-timer'),
                      style: text.titleMedium?.copyWith(
                        color: AppColors.textMuted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (done)
              const InlineBanner(
                key: Key('prescription-done'),
                tone: BannerTone.success,
                message:
                    'You have done every set. End the session when you are ready.',
              )
            else if (stored != null)
              _feedback(stored)
            else
              const InlineBanner(
                key: Key('rep-feedback'),
                tone: BannerTone.info,
                icon: Icons.accessibility_new_rounded,
                message:
                    'Start when you are ready. Each repetition is counted for you.',
              ),
          ] else ...[
            Text('Session time', style: text.titleLarge),
            const SizedBox(height: 8),
            Text(
              _clockText(_elapsed),
              key: const Key('session-timer'),
              style: const TextStyle(
                fontSize: 56,
                height: 1.1,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
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
          Text(requirements.exercise.instructions, style: text.bodyMedium),
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
            busy: _ending,
            onPressed: _end,
          ),
        ],
      ),
    );
  }

  /// What the server found in the last repetition. INFO and AMBER are shown
  /// here and the session carries on; RED never reaches this banner, because
  /// it pauses the session instead.
  Widget _feedback(RecordedRepetition stored) {
    final worst = stored.feedback.isEmpty ? null : stored.feedback.first;
    final (tone, icon, message) = switch (stored.tier) {
      FeedbackTier.amber => (
        BannerTone.warning,
        Icons.warning_amber_rounded,
        worst?.message ?? 'Check your form on the next one.',
      ),
      FeedbackTier.info => (
        BannerTone.info,
        Icons.lightbulb_outline_rounded,
        worst?.message ?? 'A small thing to refine.',
      ),
      _ => (
        BannerTone.success,
        Icons.check_circle_outline_rounded,
        'Good repetition.',
      ),
    };
    return Semantics(
      liveRegion: true,
      child: InlineBanner(
        key: Key('rep-feedback-${stored.tier.name}'),
        tone: tone,
        icon: icon,
        message: message,
      ),
    );
  }

  /// The safety pause: a RED repetition stops everything until the patient
  /// has read what to change.
  Widget _paused(SessionPause pause) {
    final text = Theme.of(context).textTheme;
    return AppCard(
      key: const Key('safety-pause'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.pause_circle_filled_rounded,
                color: AppColors.error,
                size: 32,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text('Session paused', style: text.titleLarge)),
            ],
          ),
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.errorTint,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                pause.message,
                key: const Key('pause-message'),
                style: text.titleMedium?.copyWith(
                  color: AppColors.error,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'That last repetition could put strain on your body, so nothing '
            'is being counted. Read the message, get back into position, and '
            'continue only if it feels comfortable. If anything hurts, stop '
            'and speak to your physiotherapist.',
            style: text.bodyMedium,
          ),
          if (_pauseError != null) ...[
            const SizedBox(height: 12),
            InlineBanner(key: const Key('pause-error'), message: _pauseError!),
          ],
          const SizedBox(height: 20),
          BusyButton(
            key: const Key('acknowledge-pause'),
            label: 'I understand, continue',
            busy: _acknowledging,
            onPressed: _acknowledge,
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('end-session'),
            onPressed: _ending || _acknowledging ? null : _end,
            child: const Text('End session instead'),
          ),
        ],
      ),
    );
  }

  /// What the session came to, read from what the server stored.
  Widget _summary(PrecheckRequirements requirements, ExerciseSession ended) {
    final text = Theme.of(context).textTheme;
    final summary = ended.summary;
    final totals = summary?.totals ?? ended.totals;
    final counted = _engine?.canCount ?? false;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: AppCard(
          key: const Key('session-summary'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: AppColors.success,
                size: 48,
              ),
              const SizedBox(height: 12),
              Text(
                'Session complete',
                textAlign: TextAlign.center,
                style: text.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                requirements.exercise.name,
                textAlign: TextAlign.center,
                style: text.bodyLarge?.copyWith(color: AppColors.textMuted),
              ),
              if (counted && summary != null) ...[
                const SizedBox(height: 20),
                Center(
                  child: ScoreBadge(
                    key: const Key('summary-score'),
                    score: summary.formScore,
                    size: 96,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  summary.formScore == null
                      ? 'No form score: there was nothing to score.'
                      : 'Form score out of 100',
                  key: const Key('summary-score-label'),
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
                ),
                const SizedBox(height: 8),
                Text(
                  summary.trend,
                  key: const Key('summary-trend'),
                  textAlign: TextAlign.center,
                  style: text.bodyLarge,
                ),
              ],
              const SizedBox(height: 20),
              _SummaryRow(
                key: const Key('summary-time'),
                label: 'Time',
                value: summary == null
                    ? _minutes(_elapsed)
                    : formatDuration(summary.durationSeconds),
              ),
              if (counted) ...[
                _SummaryRow(
                  key: const Key('summary-repetitions'),
                  label: 'Repetitions',
                  value: '${totals.repetitions}',
                ),
                _SummaryRow(
                  key: const Key('summary-ok'),
                  label: 'Good form',
                  value: '${totals.ok}',
                ),
                _SummaryRow(
                  key: const Key('summary-info'),
                  label: 'Small things to refine',
                  value: '${totals.info}',
                ),
                _SummaryRow(
                  key: const Key('summary-amber'),
                  label: 'Form to work on',
                  value: '${totals.amber}',
                ),
                _SummaryRow(
                  key: const Key('summary-red'),
                  label: 'Paused for safety',
                  value: '${totals.red}',
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('summary-done'),
                onPressed: _leave,
                child: const Text('Back to my plan'),
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

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          Expanded(child: Text(label, style: text.bodyLarge)),
          Text(
            value,
            style: text.titleMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({super.key, required this.label, required this.state});

  final String label;

  /// True when met, false when not, null while not known yet.
  final bool? state;

  @override
  Widget build(BuildContext context) {
    final (icon, color, meaning) = switch (state) {
      true => (Icons.check_circle_rounded, AppColors.success, 'done'),
      false => (
        Icons.radio_button_unchecked_rounded,
        AppColors.warning,
        'not yet',
      ),
      null => (Icons.more_horiz_rounded, AppColors.textMuted, 'checking'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color, semanticLabel: meaning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws the tracked body over the camera picture, so the patient can see
/// what the app sees.
class _SkeletonPainter extends CustomPainter {
  _SkeletonPainter({
    required this.frame,
    required this.required,
    required this.minVisibility,
  });

  final PoseFrame frame;
  final Set<String> required;
  final double minVisibility;

  @override
  void paint(Canvas canvas, Size size) {
    Offset? at(String name) {
      final point = frame.landmarks[name];
      if (point == null || point.visibility < minVisibility) return null;
      return Offset(point.x * size.width, point.y * size.height);
    }

    final bone = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final (from, to) in poseBones) {
      final a = at(from);
      final b = at(to);
      if (a != null && b != null) canvas.drawLine(a, b, bone);
    }
    for (final name in required) {
      final point = at(name);
      if (point == null) continue;
      canvas.drawCircle(point, 7, Paint()..color = Colors.white);
      canvas.drawCircle(point, 5, Paint()..color = AppColors.teal);
    }
  }

  @override
  bool shouldRepaint(_SkeletonPainter old) => old.frame != frame;
}
