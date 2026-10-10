import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/animations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/hologram/holo_figure.dart';
import '../../../core/widgets/ui_components.dart';
import 'auth_scaffold.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AuthScaffold(
      trailing: TextButton(
        onPressed: () => context.go('/sign-in'),
        child: const Text('Sign in'),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 860;
          final intro = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Pill(
                'AI-assisted physiotherapy',
                foreground: AppColors.primaryDark,
                background: AppColors.primaryTint,
              ),
              const SizedBox(height: 20),
              Text(
                'Smarter rehabilitation.\nBetter movement.',
                style: wide ? text.displaySmall : text.headlineMedium,
              ),
              const SizedBox(height: 16),
              Text(
                'Do the exercises your physiotherapist assigns, at home. PhysioAI watches your '
                'movement through your camera and gives you gentle, real-time feedback on your form.',
                style: text.bodyLarge?.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(height: 28),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton(
                    onPressed: () => context.go('/sign-in'),
                    child: const Text('Get Started'),
                  ),
                  OutlinedButton(
                    onPressed: () => context.go('/sign-in'),
                    child: const Text('Sign In'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                "PhysioAI supports your physiotherapist's care. It does not diagnose conditions.",
                style: text.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
            ],
          );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(flex: 6, child: intro),
                    const SizedBox(width: 48),
                    const Expanded(flex: 5, child: _HeroVisual()),
                  ],
                )
              else ...[
                intro,
                const SizedBox(height: 32),
                const _HeroVisual(),
              ],
              const SizedBox(height: 48),
              _Features(wide: wide),
            ],
          );
        },
      ),
    );
  }
}

class _HeroVisual extends StatelessWidget {
  const _HeroVisual();

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.05,
      child: Container(
        decoration: BoxDecoration(
          gradient: AppColors.holoGradient,
          borderRadius: BorderRadius.circular(AppTheme.radiusXL + 4),
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: AppTheme.elevatedShadow,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            const Positioned.fill(
              child: Padding(
                padding: EdgeInsets.fromLTRB(12, 36, 12, 64),
                child: HoloFigure(
                  exercise: HoloExercise.squat,
                  tone: HoloTone.neutral,
                  semanticLabel: 'A 3D figure performing a squat',
                ),
              ),
            ),
            Positioned(
              left: 16,
              top: 16,
              child: _GlassChip(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Pulse(
                      scale: 1.3,
                      child: Icon(
                        Icons.circle,
                        size: 8,
                        color: AppColors.success,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Tracking active',
                      style: AppTheme.labelBold.copyWith(
                        color: AppColors.text,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 16,
              top: 16,
              child: _GlassChip(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'FORM SCORE',
                      style: AppTheme.labelBold.copyWith(
                        color: AppColors.textMuted,
                        fontSize: 10,
                      ),
                    ),
                    Text(
                      '92',
                      style: AppTheme.statNumber.copyWith(fontSize: 26),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
                  border: Border.all(color: Colors.white),
                  boxShadow: AppTheme.cardShadow,
                ),
                child: const Row(
                  children: [
                    GlyphTile(icon: Icons.auto_awesome_rounded, size: 34),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Great form. Keep your knees in line with your toes.',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          fontWeight: FontWeight.w500,
                          color: AppColors.text,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassChip extends StatelessWidget {
  const _GlassChip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: Colors.white),
        boxShadow: AppTheme.cardShadow,
      ),
      child: child,
    );
  }
}

class _Features extends StatelessWidget {
  const _Features({required this.wide});

  final bool wide;

  static const _items = [
    (
      Icons.assignment_ind_outlined,
      'Assigned by your physiotherapist',
      'Your plan comes from the clinician who knows your recovery.',
    ),
    (
      Icons.videocam_outlined,
      'Real-time movement feedback',
      'Small, clear corrections while you exercise, not afterwards.',
    ),
    (
      Icons.trending_up_rounded,
      'Progress your physiotherapist can see',
      'Each session is summarised and shared with them.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final cards = [
      for (final (icon, title, body) in _items)
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlyphTile(icon: icon, size: 48),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                body,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
    ];
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final card in cards)
            Padding(padding: const EdgeInsets.only(bottom: 16), child: card),
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(width: 24),
            Expanded(child: cards[i]),
          ],
        ],
      ),
    );
  }
}
