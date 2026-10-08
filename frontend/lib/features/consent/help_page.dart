import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/common.dart';
import '../shell/page_widgets.dart';
import 'advisory_content.dart';
import 'consent_repository.dart';

/// Where a patient can re-read the advisory at any time: the same wording they
/// acknowledged, with the date they did so.
class PatientHelpPage extends ConsumerWidget {
  const PatientHelpPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(consentStatusProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageIntro(
          title: 'Advisory',
          subtitle: 'What PhysioAI does, and what it does not do.',
        ),
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: AppCard(
              child: AsyncSection(
                value: status,
                onRetry: () => ref.invalidate(consentStatusProvider),
                builder: (status) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      status.disclaimer.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    AdvisoryContent(disclaimer: status.disclaimer),
                    if (status.acknowledgedAt != null) ...[
                      const SizedBox(height: 20),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Pill.success(
                          'You acknowledged this on ${formatDateTime(status.acknowledgedAt!)}',
                          key: const Key('advisory-acknowledged-at'),
                          icon: Icons.check_circle_outline_rounded,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
