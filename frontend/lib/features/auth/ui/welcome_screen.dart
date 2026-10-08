import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';
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
      aspectRatio: 1.15,
      child: AppCard(
        color: const Color(0xFFF1F3FF),
        padding: EdgeInsets.zero,
        child: Stack(
          children: [
            const Positioned.fill(child: CustomPaint(painter: _PosePainter())),
            Positioned(
              left: 16,
              top: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(100),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, size: 8, color: AppColors.success),
                    SizedBox(width: 6),
                    Text(
                      'Tracking active',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
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
                  color: AppColors.purpleTint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_outlined,
                      size: 18,
                      color: AppColors.purple,
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Great form. Keep your knees in line with your toes.',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          color: AppColors.purpleDark,
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

/// A simple squat pose drawn as a skeleton overlay: joints and the lines between them.
class _PosePainter extends CustomPainter {
  const _PosePainter();

  @override
  void paint(Canvas canvas, Size size) {
    Offset at(double x, double y) => Offset(size.width * x, size.height * y);
    final head = at(0.47, 0.20);
    final neck = at(0.47, 0.30);
    final shoulder = at(0.46, 0.33);
    final hand = at(0.70, 0.36);
    final hip = at(0.38, 0.55);
    final knee = at(0.58, 0.62);
    final ankle = at(0.52, 0.80);
    final toe = at(0.62, 0.81);

    final bone = Paint()
      ..color = AppColors.teal
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    for (final (a, b) in [
      (neck, shoulder),
      (shoulder, hand),
      (shoulder, hip),
      (hip, knee),
      (knee, ankle),
      (ankle, toe),
    ]) {
      canvas.drawLine(a, b, bone);
    }
    canvas.drawCircle(
      head,
      size.shortestSide * 0.055,
      Paint()
        ..color = AppColors.teal
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
    final joint = Paint()..color = Colors.white;
    final jointRing = Paint()
      ..color = AppColors.tealDark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    for (final point in [shoulder, hand, hip, knee, ankle]) {
      canvas.drawCircle(point, 6, joint);
      canvas.drawCircle(point, 6, jointRing);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
              Icon(icon, color: AppColors.primary, size: 28),
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
