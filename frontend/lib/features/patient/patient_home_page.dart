import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../auth/auth_controller.dart';
import '../exercises/exercise_models.dart';
import '../shell/page_widgets.dart';
import 'patient_repository.dart';

class PatientHomePage extends ConsumerWidget {
  const PatientHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    if (user == null) return const SizedBox.shrink();
    final physio = user.physiotherapist;
    final plan = ref.watch(patientPlanProvider);
    final text = Theme.of(context).textTheme;
    final count = plan.valueOrNull?.items.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageIntro(
          title: '${greetingFor(DateTime.now())}, ${user.account.firstName}',
          subtitle: switch (count) {
            null => 'Your account is linked to your physiotherapist.',
            1 => 'You have 1 exercise in your plan.',
            _ => 'You have $count exercises in your plan.',
          },
        ),
        ResponsiveRow(
          flex: const [3, 2],
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('Your exercises', style: text.titleLarge),
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
                            children: [
                              for (final item in plan.items)
                                _ExerciseRow(item: item),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your physiotherapist', style: text.titleLarge),
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
                        const CircleAvatar(
                          radius: 22,
                          backgroundColor: AppColors.primaryTint,
                          child: Icon(
                            Icons.medical_services_outlined,
                            color: AppColors.primary,
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
                                style: text.titleMedium,
                              ),
                              Text(
                                'Assigns and reviews your exercises',
                                style: text.bodySmall?.copyWith(
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ExerciseRow extends StatelessWidget {
  const _ExerciseRow({required this.item});

  final PlanItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 15,
            backgroundColor: AppColors.tealTint,
            child: Text(
              '${item.position}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.tealDark,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.exercise.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  item.prescription,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          Pill.neutral(item.difficulty.label),
        ],
      ),
    );
  }
}
