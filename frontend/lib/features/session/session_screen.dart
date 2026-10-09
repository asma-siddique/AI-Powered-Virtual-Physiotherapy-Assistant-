import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../patient/patient_repository.dart';
import '../shell/page_widgets.dart';
import 'pose/pose_models.dart';
import 'pose/pose_source.dart';
import 'precheck.dart';

/// One exercise in front of the camera: first the camera check, then the
/// session itself. The session starts by itself once the setup has held good
/// for a moment, because the patient is standing well back from the device.
/// Nothing is counted or scored before that.
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
      setState(() {
        _session = session;
        _starting = false;
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

  void _leave() => context.go('/patient/plan');

  Future<void> _end() async {
    final session = _session;
    if (session == null || _ending) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End this session?'),
        content: const Text(
          'Your session will be saved with the time you exercised.',
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
      await ref.read(patientRepositoryProvider).endSession(session.id);
      _clock?.cancel();
      if (!mounted) return;
      _leave();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Session saved: ${_minutes(_elapsed)} of ${_tracker!.requirements.exercise.name}.',
          ),
        ),
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _ending = false);
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  static String _minutes(Duration time) {
    final minutes = time.inMinutes;
    final seconds = time.inSeconds % 60;
    if (minutes == 0) return '$seconds seconds';
    return '$minutes min ${seconds.toString().padLeft(2, '0')} s';
  }

  static String _clockText(Duration time) =>
      '${time.inMinutes.toString().padLeft(2, '0')}:'
      '${(time.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final requirements = ref.watch(precheckRequirementsProvider(widget.itemId));
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final live = _session != null;

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
                  if (live)
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
              _session == null ? _setup(requirements) : _live(requirements),
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
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
          const SizedBox(height: 16),
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
          const SizedBox(height: 16),
          Text(requirements.exercise.instructions, style: text.bodyMedium),
          const SizedBox(height: 12),
          Text(
            'Automatic rep counting and form feedback are the next part of '
            'PhysioAI to be built. For now this session records the time you exercised.',
            style: text.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
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
