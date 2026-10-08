import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../exercises/exercise_models.dart';
import '../shell/page_widgets.dart';
import 'patient_repository.dart';

/// "My Exercise Plan": what the physiotherapist has assigned, in order.
class ExercisePlanPage extends ConsumerWidget {
  const ExercisePlanPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(patientPlanProvider);
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
            for (final item in plan.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: PlanItemCard(item: item),
              ),
          ],
        );
      },
    );
  }
}

/// One prescribed exercise, as the patient reads it.
class PlanItemCard extends StatelessWidget {
  const PlanItemCard({super.key, required this.item});

  final PlanItem item;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final exercise = item.exercise;
    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.tealTint,
            child: Text(
              '${item.position}',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.tealDark,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(exercise.name, style: text.titleLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Pill(
                      item.prescription,
                      foreground: AppColors.primaryDark,
                      background: AppColors.primaryTint,
                    ),
                    Pill.neutral(item.rest),
                    Pill.neutral(item.difficulty.label),
                    if (!exercise.isActive)
                      const Pill.warning('Being updated by your clinic'),
                  ],
                ),
                const SizedBox(height: 12),
                Text(exercise.instructions, style: text.bodyLarge),
                const SizedBox(height: 8),
                Text(
                  'Works: ${exercise.primaryTargets}',
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
                if (item.note != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Note from your physiotherapist: ${item.note}',
                      style: text.bodyMedium?.copyWith(
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
