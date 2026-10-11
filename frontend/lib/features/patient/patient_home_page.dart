import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/animations.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/hologram/holo_figure.dart';
import '../../core/widgets/hologram/holo_scene.dart';
import '../../core/widgets/ui_components.dart';
import '../auth/auth_controller.dart';
import '../exercises/exercise_models.dart';
import '../session/session_records.dart';
import '../shell/page_widgets.dart';
import 'patient_repository.dart';

/// What the patient's recent sessions add up to, for the home screen.
class _Activity {
  _Activity(List<SessionBrief> sessions, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final lastWeekStart = weekStart.subtract(const Duration(days: 7));
    final days = <DateTime>{};
    final thisWeek = <int>[];
    final lastWeek = <int>[];
    for (final session in sessions) {
      final at = session.startedAt.toLocal();
      final day = DateTime(at.year, at.month, at.day);
      days.add(day);
      if (day == today) doneToday.add(session.exercise.id);
      if (!day.isBefore(weekStart)) {
        sessionsThisWeek++;
        if (session.formScore case final score?) thisWeek.add(score);
      } else if (!day.isBefore(lastWeekStart)) {
        if (session.formScore case final score?) lastWeek.add(score);
      }
    }
    if (thisWeek.isNotEmpty) {
      averageScore = (thisWeek.reduce((a, b) => a + b) / thisWeek.length)
          .round();
    }
    if (thisWeek.isNotEmpty && lastWeek.isNotEmpty) {
      final before = lastWeek.reduce((a, b) => a + b) / lastWeek.length;
      if (before > 0) {
        improvement = ((averageScore! - before) / before * 100).round();
      }
    }
    // Consecutive days with a session, ending today or yesterday.
    var day = days.contains(today)
        ? today
        : today.subtract(const Duration(days: 1));
    while (days.contains(day)) {
      streak++;
      day = day.subtract(const Duration(days: 1));
    }
  }

  final doneToday = <String>{};
  int sessionsThisWeek = 0;
  int? averageScore;

  /// Percentage change of the average score against last week.
  int? improvement;
  int streak = 0;
}

class PatientHomePage extends ConsumerWidget {
  const PatientHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    if (user == null) return const SizedBox.shrink();
    final physio = user.physiotherapist;
    final plan = ref.watch(patientPlanProvider);
    final sessions = ref.watch(patientSessionsProvider).valueOrNull ?? const [];
    final activity = _Activity(sessions, DateTime.now());
    final count = plan.valueOrNull?.items.length;
    final items = plan.valueOrNull?.items ?? const <PlanItem>[];
    PlanItem? next;
    for (final item in items) {
      if (item.exercise.isActive &&
          !activity.doneToday.contains(item.exercise.id)) {
        next = item;
        break;
      }
    }
    final upNext = next;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hero(
          greeting: '${greetingFor(DateTime.now())}, ${user.account.firstName}',
          subtitle: switch (count) {
            null => 'Your account is linked to your physiotherapist.',
            1 => 'You have 1 exercise in your plan.',
            _ => 'You have $count exercises in your plan.',
          },
          next: upNext,
          onStart: upNext == null
              ? null
              : () => context.go('/patient/session/${upNext.id}'),
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final tiles = [
              StatTile(
                value: '${activity.sessionsThisWeek}',
                label: 'Sessions this week',
                icon: Icons.event_available_rounded,
              ),
              StatTile(
                value: activity.averageScore == null
                    ? '–'
                    : '${activity.averageScore}',
                label: 'Avg form score',
                icon: Icons.speed_rounded,
                color: AppColors.navy,
                trailing:
                    activity.improvement == null || activity.improvement == 0
                    ? null
                    : Icon(
                        activity.improvement! > 0
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 20,
                        color: activity.improvement! > 0
                            ? AppColors.severityGreen
                            : AppColors.severityRed,
                      ),
              ),
              StatTile(
                value: '${activity.streak}',
                label: 'Day streak',
                icon: Icons.local_fire_department_rounded,
                color: AppColors.severityAmber,
                trailing: const Icon(
                  Icons.local_fire_department_rounded,
                  size: 22,
                  color: Color(0xFFFF9800),
                ),
              ),
            ];
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < tiles.length; i++) ...[
                    if (i > 0)
                      SizedBox(width: constraints.maxWidth < 500 ? 8 : 16),
                    Expanded(
                      child: SlideUpIn(
                        delay: Duration(milliseconds: 80 * i),
                        child: tiles[i],
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 20),
        ResponsiveRow(
          flex: const [3, 2],
          gap: 20,
          children: [
            AppCard(
              accent: AppColors.primary,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Your exercises',
                          style: AppTheme.headingLarge,
                        ),
                      ),
                      if (count != null)
                        TextButton(
                          onPressed: () => context.go('/patient/plan'),
                          child: const Text('View full plan'),
                        ),
                    ],
                  ),
                  AsyncSection(
                    value: plan,
                    onRetry: () => ref.invalidate(patientPlanProvider),
                    builder: (plan) => plan == null
                        ? const EmptyState(
                            icon: Icons.assignment_outlined,
                            message:
                                'No exercises have been assigned yet.\n'
                                'Your physiotherapist will set up your plan, and it will appear here.',
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 8),
                              _TodayProgress(
                                done: [
                                  for (final item in plan.items)
                                    if (activity.doneToday.contains(
                                      item.exercise.id,
                                    ))
                                      item,
                                ].length,
                                total: plan.items.length,
                              ),
                              const SizedBox(height: 12),
                              for (final item in plan.items)
                                _ExerciseRow(
                                  item: item,
                                  done: activity.doneToday.contains(
                                    item.exercise.id,
                                  ),
                                  next: item == upNext,
                                ),
                              if (upNext != null) ...[
                                const SizedBox(height: 16),
                                PrimaryButton(
                                  label: 'Start Next Exercise',
                                  trailingIcon: Icons.arrow_forward_rounded,
                                  expand: true,
                                  onPressed: () => context.go(
                                    '/patient/session/${upNext.id}',
                                  ),
                                ),
                              ],
                            ],
                          ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your physiotherapist',
                        style: AppTheme.headingMedium,
                      ),
                      const SizedBox(height: 16),
                      if (physio == null)
                        const InlineBanner(
                          tone: BannerTone.info,
                          message:
                              'You are not linked to a physiotherapist right now. Contact your clinic.',
                        )
                      else
                        Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: const BoxDecoration(
                                gradient: AppColors.cardGradient,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.medical_services_outlined,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    physio.fullName,
                                    key: const Key('linked-physio'),
                                    style: AppTheme.headingSmall,
                                  ),
                                  Text(
                                    'Assigns and reviews your exercises',
                                    style: AppTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _Motivation(
                  name: user.account.firstName,
                  improvement: activity.improvement,
                  streak: activity.streak,
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// The greeting, in the dark where the holograms live: the figure performs
/// the exercise that is up next in the plan.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.greeting,
    required this.subtitle,
    this.next,
    this.onStart,
  });

  final String greeting;
  final String subtitle;

  /// The exercise that is up next, if any is left today.
  final PlanItem? next;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final upNext = next;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.radiusXL),
        boxShadow: AppTheme.elevatedShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: HoloNight(
        horizon: 0.7,
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                narrow ? 20 : AppTheme.paddingXXL,
                narrow ? 20 : 28,
                narrow ? 8 : 16,
                narrow ? 20 : 28,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(100),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.18),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Pulse(
                                scale: 1.3,
                                child: Icon(
                                  Icons.circle,
                                  size: 8,
                                  color: AppColors.primaryMint,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'AI COACH READY',
                                style: AppTheme.labelBold.copyWith(
                                  color: Colors.white,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          greeting,
                          style: AppTheme.displayLarge.copyWith(
                            color: Colors.white,
                            fontSize: narrow ? 24 : 30,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          subtitle,
                          style: AppTheme.bodyLarge.copyWith(
                            color: AppColors.primaryMint,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (upNext != null) ...[
                          const SizedBox(height: 16),
                          HoloChip(
                            key: const Key('up-next'),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: 'UP NEXT   ',
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.6,
                                      ),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.1,
                                    ),
                                  ),
                                  TextSpan(
                                    text:
                                        '${upNext.exercise.name}  ·  '
                                        '${upNext.prescription}',
                                  ),
                                ],
                              ),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                        if (onStart != null) ...[
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            onPressed: onStart,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.primaryMint,
                              foregroundColor: AppColors.night,
                            ),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: Text(
                              narrow
                                  ? 'Start session'
                                  : 'Start today’s session',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(
                    width: narrow ? 120 : 300,
                    height: narrow ? 170 : 300,
                    child: HoloFigure(
                      exercise: upNext == null
                          ? HoloExercise.stand
                          : HoloExercise.of(
                              upNext.exercise.slug,
                              upNext.exercise.name,
                            ),
                      tone: HoloTone.correct,
                      semanticLabel: upNext == null
                          ? 'Your PhysioAI coach'
                          : 'A hologram performing ${upNext.exercise.name}',
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
}

class _TodayProgress extends StatelessWidget {
  const _TodayProgress({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              "TODAY'S PLAN",
              style: AppTheme.labelBold.copyWith(color: AppColors.textMuted),
            ),
            const Spacer(),
            Text(
              '$done of $total completed',
              style: AppTheme.labelBold.copyWith(
                color: AppColors.primary,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ProgressTrack(value: total == 0 ? 0 : done / total),
      ],
    );
  }
}

class _ExerciseRow extends StatelessWidget {
  const _ExerciseRow({
    required this.item,
    required this.done,
    required this.next,
  });

  final PlanItem item;
  final bool done;
  final bool next;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: next
            ? AppColors.primaryTint.withValues(alpha: 0.6)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(
          color: next
              ? AppColors.primary.withValues(alpha: 0.3)
              : AppColors.divider,
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            height: 72,
            child: HoloStage(
              dark: true,
              radius: 12,
              child: HoloFigure(
                exercise: HoloExercise.of(
                  item.exercise.slug,
                  item.exercise.name,
                ),
                animate: next,
                guides: false,
                pedestal: false,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.exercise.name, style: AppTheme.headingSmall),
                Text(item.prescription, style: AppTheme.bodyMedium),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (done)
            const Icon(
              Icons.check_circle_rounded,
              color: AppColors.severityGreen,
              size: 26,
              semanticLabel: 'Done today',
            )
          else
            DifficultyPill(item.difficulty),
        ],
      ),
    );
  }
}

/// Easy is green, Medium amber, Hard red.
class DifficultyPill extends StatelessWidget {
  const DifficultyPill(this.difficulty, {super.key});

  final Difficulty difficulty;

  @override
  Widget build(BuildContext context) {
    final severity = switch (difficulty) {
      Difficulty.easy => Severity.good,
      Difficulty.medium => Severity.amber,
      Difficulty.hard => Severity.red,
    };
    return Pill(
      difficulty.label,
      foreground: severity.color,
      background: severity.background,
    );
  }
}

class _Motivation extends StatelessWidget {
  const _Motivation({
    required this.name,
    required this.improvement,
    required this.streak,
  });

  final String name;
  final int? improvement;
  final int streak;

  @override
  Widget build(BuildContext context) {
    final change = improvement;
    final line = change != null && change > 0
        ? 'Your form improved $change% this week.'
        : streak > 1
        ? 'That is $streak days in a row. Consistency builds recovery.'
        : 'Small steps every day add up to a strong recovery.';
    return Container(
      padding: const EdgeInsets.all(AppTheme.paddingL),
      decoration: BoxDecoration(
        gradient: AppColors.heroGradient,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        boxShadow: AppTheme.elevatedShadow,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Keep going, $name!',
                  style: AppTheme.headingMedium.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 4),
                Text(
                  line,
                  style: AppTheme.bodyMedium.copyWith(color: Colors.white70),
                ),
                const SizedBox(height: 10),
                InkWell(
                  onTap: () => context.go('/patient/progress'),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'View progress',
                          style: AppTheme.labelBold.copyWith(
                            color: AppColors.primaryMint,
                            fontSize: 13,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.arrow_forward_rounded,
                          size: 16,
                          color: AppColors.primaryMint,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.auto_graph_rounded, color: Colors.white24, size: 56),
        ],
      ),
    );
  }
}
