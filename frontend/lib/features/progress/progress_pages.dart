import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/hologram/holo_figure.dart';
import '../exercises/exercise_models.dart';
import '../patient/patient_repository.dart';
import '../session/session_records.dart';
import '../shell/page_widgets.dart';
import 'session_widgets.dart';

void _open(BuildContext context, WidgetRef ref, SessionBrief session) =>
    showSessionDetail(
      context,
      load: () => ref.read(patientRepositoryProvider).sessionDetail(session.id),
    );

/// "Session History": every session the patient has finished, newest first.
class SessionHistoryPage extends ConsumerWidget {
  const SessionHistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(patientSessionsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageIntro(
          title: 'Session History',
          subtitle: 'Every session you have done, most recent first.',
        ),
        AsyncSection(
          value: sessions,
          onRetry: () => ref.invalidate(patientSessionsProvider),
          builder: (sessions) => sessions.isEmpty
              ? const AppCard(
                  child: EmptyState(
                    icon: Icons.history_rounded,
                    message:
                        'You have not finished a session yet.\n'
                        'Start one from My Exercise Plan and it will appear here.',
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final session in sessions)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: SessionCard(
                          session: session,
                          onOpen: () => _open(context, ref, session),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// How far back the trend looks.
enum ProgressRange {
  month('30 days', 30),
  quarter('3 months', 91),
  year('12 months', 365),
  all('All time', null);

  const ProgressRange(this.label, this.days);

  final String label;
  final int? days;

  bool includes(DateTime at, DateTime now) =>
      days == null || !at.isBefore(now.subtract(Duration(days: days!)));
}

/// "Progress": the form-score trend of one exercise over a chosen range.
class ProgressPage extends ConsumerStatefulWidget {
  const ProgressPage({super.key});

  @override
  ConsumerState<ProgressPage> createState() => _ProgressPageState();
}

class _ProgressPageState extends ConsumerState<ProgressPage> {
  String? _exerciseId;
  ProgressRange _range = ProgressRange.quarter;

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(patientSessionsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageIntro(
          title: 'Progress',
          subtitle: 'How your form score has changed from session to session.',
        ),
        AsyncSection(
          value: sessions,
          onRetry: () => ref.invalidate(patientSessionsProvider),
          builder: (sessions) => sessions.isEmpty
              ? const AppCard(
                  child: EmptyState(
                    icon: Icons.trending_up_rounded,
                    message:
                        'Your progress will appear here once you have '
                        'finished a session.',
                  ),
                )
              : _progress(sessions),
        ),
      ],
    );
  }

  Widget _progress(List<SessionBrief> sessions) {
    final text = Theme.of(context).textTheme;
    // Exercises in the order last performed.
    final exercises = {
      for (final session in sessions) session.exercise.id: session.exercise,
    };
    final exerciseId = exercises.containsKey(_exerciseId)
        ? _exerciseId!
        : exercises.keys.first;
    final now = DateTime.now();
    final inRange = [
      for (final session in sessions)
        if (session.exercise.id == exerciseId &&
            _range.includes(session.startedAt, now))
          session,
    ];
    final points = <TrendPoint>[
      for (final session in inRange.reversed)
        if (session.formScore case final score?)
          (at: session.startedAt.toLocal(), score: score),
    ];
    final unscored = inRange.length - points.length;

    // The latest score of each exercise, for the cards along the top.
    final latest = <String, int?>{};
    for (final session in sessions) {
      if (!latest.containsKey(session.exercise.id) ||
          latest[session.exercise.id] == null) {
        latest[session.exercise.id] = session.formScore;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 112,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: exercises.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final exercise = exercises.values.elementAt(i);
              return _ExerciseScoreCard(
                exercise: exercise,
                score: latest[exercise.id],
                selected: exercise.id == exerciseId,
                onTap: () => setState(() => _exerciseId = exercise.id),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<String>(
                    key: const Key('progress-exercise'),
                    value: exerciseId,
                    underline: const SizedBox.shrink(),
                    style: text.titleMedium,
                    items: [
                      for (final exercise in exercises.values)
                        DropdownMenuItem(
                          value: exercise.id,
                          child: Text(exercise.name),
                        ),
                    ],
                    onChanged: (value) => setState(() => _exerciseId = value),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final range in ProgressRange.values)
                        ChoiceChip(
                          key: Key('progress-range-${range.name}'),
                          label: Text(range.label),
                          selected: range == _range,
                          labelStyle: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: range == _range
                                ? Colors.white
                                : AppColors.text,
                          ),
                          selectedColor: AppColors.primary,
                          side: BorderSide(
                            color: range == _range
                                ? AppColors.primary
                                : AppColors.border,
                          ),
                          onSelected: (_) => setState(() => _range = range),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (points.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    inRange.isEmpty
                        ? 'No sessions of this exercise in this period.'
                        : 'No session in this period had anything to score.',
                    key: const Key('progress-empty'),
                    textAlign: TextAlign.center,
                    style: text.bodyLarge?.copyWith(color: AppColors.textMuted),
                  ),
                )
              else ...[
                TrendChart(key: const Key('progress-chart'), points: points),
                const SizedBox(height: 12),
                Text(
                  _reading(points),
                  key: const Key('progress-reading'),
                  style: text.bodyLarge,
                ),
              ],
              if (unscored > 0 && points.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  unscored == 1
                      ? '1 session in this period had nothing to score and is not on the graph.'
                      : '$unscored sessions in this period had nothing to score and are not on the graph.',
                  key: const Key('progress-unscored'),
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
        if (inRange.isNotEmpty) ...[
          Text('Sessions in this period', style: text.titleLarge),
          const SizedBox(height: 12),
          for (final (i, session) in inRange.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: DecoratedBox(
                // Alternate rows sit on a faint wash for easier scanning.
                decoration: BoxDecoration(
                  color: i.isOdd ? AppColors.surfaceAlt : Colors.transparent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: SessionCard(
                  session: session,
                  onOpen: () => _open(context, ref, session),
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// The trend in a sentence, for those who do not read graphs.
  static String _reading(List<TrendPoint> points) {
    if (points.length == 1) {
      return 'One scored session so far: ${points.single.score} out of 100.';
    }
    final first = points.first.score;
    final last = points.last.score;
    final change = last - first;
    final over = '${points.length} scored sessions';
    if (change == 0) return 'Steady at $last out of 100 over $over.';
    return change > 0
        ? 'Up from $first to $last over $over.'
        : 'Down from $first to $last over $over.';
  }
}

/// One exercise along the top of Progress: its hologram and latest score.
class _ExerciseScoreCard extends StatelessWidget {
  const _ExerciseScoreCard({
    required this.exercise,
    required this.score,
    required this.selected,
    required this.onTap,
  });

  final ExerciseBrief exercise;
  final int? score;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final value = score;
    final color = value == null
        ? AppColors.textHint
        : value > 80
        ? AppColors.severityGreen
        : value >= 60
        ? AppColors.severityAmber
        : AppColors.severityRed;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 236,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        border: Border.all(
          color: selected ? AppColors.primary : AppColors.divider,
          width: selected ? 2 : 1,
        ),
        boxShadow: selected ? AppTheme.elevatedShadow : AppTheme.cardShadow,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  height: 88,
                  child: HoloStage(
                    radius: 12,
                    child: HoloFigure(
                      exercise: HoloExercise.of(exercise.slug, exercise.name),
                      animate: selected,
                      guides: false,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        exercise.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.headingSmall.copyWith(fontSize: 14),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        value == null ? 'Not scored yet' : 'Latest score',
                        style: AppTheme.bodyMedium.copyWith(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 46,
                  height: 46,
                  child: CustomPaint(
                    painter: _MiniGauge(value ?? 0, color),
                    child: Center(
                      child: Text(
                        value == null ? '–' : '$value',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                    ),
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

class _MiniGauge extends CustomPainter {
  _MiniGauge(this.value, this.color);

  final int value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(3);
    canvas.drawArc(
      rect,
      0,
      2 * math.pi,
      false,
      Paint()
        ..color = AppColors.divider
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * value / 100,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_MiniGauge old) =>
      old.value != value || old.color != color;
}
