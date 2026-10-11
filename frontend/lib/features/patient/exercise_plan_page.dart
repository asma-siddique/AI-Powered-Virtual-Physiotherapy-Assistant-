import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/animations.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/hologram/holo_figure.dart';
import '../exercises/exercise_models.dart';
import '../shell/page_widgets.dart';
import 'patient_home_page.dart' show DifficultyPill;
import 'patient_repository.dart';
import 'reminders.dart';

/// "My Exercise Plan": what the physiotherapist has assigned, in order.
class ExercisePlanPage extends ConsumerWidget {
  const ExercisePlanPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(patientPlanProvider);
    final today = DateTime.now();
    final doneToday = {
      for (final session
          in ref.watch(patientSessionsProvider).valueOrNull ?? const [])
        if (DateUtils.isSameDay(session.startedAt.toLocal(), today))
          session.exercise.id,
    };
    return AsyncSection(
      value: plan,
      onRetry: () => ref.invalidate(patientPlanProvider),
      builder: (plan) {
        if (plan == null) {
          return const AppCard(
            child: EmptyState(
              icon: Icons.assignment_outlined,
              message:
                  'No exercises have been assigned yet.\n'
                  'Your physiotherapist will set up your plan, and it will appear here.',
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageIntro(
              title: plan.name,
              subtitle:
                  'Assigned by ${plan.assignedBy.fullName} on ${formatDate(plan.createdAt)}',
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: ReminderCard(days: plan.days),
            ),
            for (final item in plan.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: SlideUpIn(
                  delay: Duration(milliseconds: 60 * item.position),
                  child: PlanItemCard(
                    item: item,
                    done: doneToday.contains(item.exercise.id),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One prescribed exercise, as the patient reads it: a 3D hologram of the
/// movement beside what to do.
class PlanItemCard extends StatelessWidget {
  const PlanItemCard({super.key, required this.item, this.done = false});

  final PlanItem item;

  /// Performed at least once today.
  final bool done;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final exercise = item.exercise;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final figure = SizedBox(
      width: narrow ? double.infinity : 168,
      height: narrow ? 180 : 210,
      child: HoloStage(
        dark: true,
        radius: 18,
        label: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                gradient: AppColors.heroGradient,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${item.position}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  fontSize: 13,
                ),
              ),
            ),
            const Spacer(),
            if (done)
              const Icon(
                Icons.check_circle_rounded,
                color: AppColors.severityGreen,
                size: 26,
                semanticLabel: 'Done today',
              ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 16),
          child: HoloFigure(
            exercise: HoloExercise.of(exercise.slug, exercise.name),
            guides: false,
            semanticLabel: 'How ${exercise.name} is performed',
          ),
        ),
      ),
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(exercise.name, style: AppTheme.headingLarge),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Pill(
              item.prescription,
              icon: Icons.repeat_rounded,
              foreground: AppColors.primaryDark,
              background: AppColors.primaryTint,
            ),
            Pill.neutral(item.rest, icon: Icons.timer_outlined),
            DifficultyPill(item.difficulty),
            if (done)
              const Pill.success('Done today', icon: Icons.check_rounded),
            if (!exercise.isActive)
              const Pill.warning('Being updated by your clinic'),
          ],
        ),
        const SizedBox(height: 12),
        Text(exercise.instructions, style: text.bodyLarge),
        const SizedBox(height: 14),
        // An exercise the clinic has switched off cannot be scored,
        // so it cannot be started until the plan is updated.
        FilledButton.icon(
          key: Key('start-item-${item.id}'),
          onPressed: exercise.isActive
              ? () => context.go('/patient/session/${item.id}')
              : null,
          icon: const Icon(Icons.videocam_outlined, size: 18),
          label: const Text('Start'),
        ),
        const SizedBox(height: 12),
        Text(
          'Works: ${exercise.primaryTargets}',
          style: text.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        if (item.wasEdited && item.updatedAt != null) ...[
          const SizedBox(height: 4),
          Text(
            'Updated by your physiotherapist on ${formatDate(item.updatedAt!)}',
            style: text.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
        if (item.note != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              border: const Border(
                left: BorderSide(color: AppColors.navy, width: 3),
              ),
            ),
            child: Text(
              'Note from your physiotherapist: ${item.note}',
              style: text.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ],
    );
    return AppCard(
      padding: const EdgeInsets.all(16),
      accent: done ? AppColors.severityGreen : null,
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [figure, const SizedBox(height: 16), details],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                figure,
                const SizedBox(width: 20),
                Expanded(child: details),
              ],
            ),
    );
  }
}
