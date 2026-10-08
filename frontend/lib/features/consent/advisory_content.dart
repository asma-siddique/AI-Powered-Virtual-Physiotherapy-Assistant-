import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import 'consent_repository.dart';

/// The advisory wording itself, shared by the acknowledgment screen and the
/// Help page.
class AdvisoryContent extends StatelessWidget {
  const AdvisoryContent({super.key, required this.disclaimer});

  final Disclaimer disclaimer;

  static const _icons = [
    Icons.videocam_outlined,
    Icons.medical_information_outlined,
    Icons.assignment_ind_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          disclaimer.intro,
          style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: 20),
        for (var i = 0; i < disclaimer.points.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primaryTint,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _icons[i % _icons.length],
                    size: 22,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        disclaimer.points[i].heading,
                        style: text.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        disclaimer.points[i].body,
                        style: text.bodyMedium?.copyWith(
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        // Amber, not red: this is guidance, not an alarm.
        InlineBanner(
          message: disclaimer.caution,
          tone: BannerTone.warning,
          icon: Icons.health_and_safety_outlined,
        ),
      ],
    );
  }
}
