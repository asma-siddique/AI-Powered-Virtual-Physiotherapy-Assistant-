import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_backdrop.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/hologram/holo_figure.dart';
import '../../../core/widgets/hologram/holo_scene.dart';

/// Page frame for the signed-out screens. On a wide screen the form sits
/// beside a hologram standing in the dark; on a narrow one there is only a
/// slim top bar with the logo and the form below it.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.child,
    this.trailing,
    this.maxWidth = 1100,
  });

  final Widget child;
  final Widget? trailing;
  final double maxWidth;

  /// From this width there is room for the hologram beside the form.
  static const _splitFrom = 1080.0;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 600;
    final split = width >= _splitFrom;

    final home = InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => context.go('/'),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: PhysioAiLogo(onDark: split),
      ),
    );

    final content = Column(
      children: [
        Container(
          height: 64,
          decoration: split
              ? null
              : BoxDecoration(
                  color: AppColors.surface.withValues(alpha: 0.6),
                  border: const Border(
                    bottom: BorderSide(color: AppColors.divider),
                  ),
                ),
          padding: EdgeInsets.symmetric(horizontal: narrow ? 16 : 40),
          child: Row(children: [if (!split) home, const Spacer(), ?trailing]),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: narrow ? 16 : 40,
              vertical: narrow ? 24 : 32,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: child,
              ),
            ),
          ),
        ),
      ],
    );

    return Scaffold(
      body: SafeArea(
        child: split
            ? Row(
                children: [
                  SizedBox(
                    width: (width * 0.36).clamp(400.0, 540.0),
                    child: _Showcase(home: home),
                  ),
                  Expanded(child: AppBackdrop(child: content)),
                ],
              )
            : AppBackdrop(child: content),
      ),
    );
  }
}

/// The dark panel beside the form: the hologram, and in three lines what
/// signing in is for.
class _Showcase extends StatelessWidget {
  const _Showcase({required this.home});

  final Widget home;

  @override
  Widget build(BuildContext context) {
    return HoloNight(
      horizon: 0.66,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(36, 14, 36, 36),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            home,
            const Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: HoloFigure(
                  exercise: HoloExercise.armAbduction,
                  tone: HoloTone.correct,
                  semanticLabel:
                      'A hologram of a person raising both arms to the side',
                ),
              ),
            ),
            const Text(
              'Your recovery,\nguided at home.',
              style: TextStyle(
                color: Colors.white,
                fontSize: 30,
                height: 1.12,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.6,
              ),
            ),
            const SizedBox(height: 16),
            for (final (icon, line) in const [
              (
                Icons.videocam_outlined,
                'Feedback on your form, repetition by repetition',
              ),
              (Icons.lock_outline_rounded, 'Your video stays on this device'),
              (
                Icons.medical_services_outlined,
                'Shared only with your physiotherapist',
              ),
            ])
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: AppColors.primaryMint),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        line,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.78),
                          fontSize: 14,
                        ),
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
