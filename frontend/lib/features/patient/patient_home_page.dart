import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../auth/auth_controller.dart';
import '../shell/page_widgets.dart';

class PatientHomePage extends ConsumerWidget {
  const PatientHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    if (user == null) return const SizedBox.shrink();
    final physio = user.physiotherapist;
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageIntro(
          title: '${greetingFor(DateTime.now())}, ${user.account.firstName}',
          subtitle:
              'Your account is set up and linked to your physiotherapist.',
        ),
        ResponsiveRow(
          flex: const [3, 2],
          children: [
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Today's exercises", style: text.titleLarge),
                  const EmptyState(
                    icon: Icons.assignment_outlined,
                    message:
                        'No exercises have been assigned yet.\n'
                        'Your physiotherapist will set up your plan, and it will appear here.',
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
