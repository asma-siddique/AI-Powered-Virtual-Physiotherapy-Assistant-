import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_backdrop.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/hologram/holo_figure.dart';
import '../../../core/widgets/hologram/holo_scene.dart';

/// The first page: what PhysioAI is, shown rather than described. A hologram
/// performs an exercise in the dark the way the app sees it; below, the
/// same things the app really does are laid out in daylight.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ice,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final wide = width >= 980;
          final gutter = width < 600 ? 20.0 : 48.0;
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Hero(wide: wide, gutter: gutter),
                // The daylight part of the page shares one background, so
                // its colour runs through all three sections.
                AppBackdrop(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Band(
                        gutter: gutter,
                        child: _HowItWorks(wide: wide),
                      ),
                      _Band(
                        gutter: gutter,
                        color: Colors.white.withValues(alpha: 0.45),
                        child: _Exercises(wide: wide),
                      ),
                      _Band(
                        gutter: gutter,
                        child: _Feedback(wide: wide),
                      ),
                    ],
                  ),
                ),
                _Closing(wide: wide, gutter: gutter),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One horizontal section of the page, its content held to a readable width.
class _Band extends StatelessWidget {
  const _Band({required this.child, required this.gutter, this.color});

  final Widget child;
  final double gutter;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: color ?? Colors.transparent,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 72),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1160),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.wide, required this.gutter});

  final bool wide;
  final double gutter;

  @override
  Widget build(BuildContext context) {
    final intro = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Eyebrow('AI-assisted physiotherapy', onDark: true),
        const SizedBox(height: 24),
        Text(
          'Smarter rehabilitation.\nBetter movement.',
          style: TextStyle(
            color: Colors.white,
            fontSize: wide ? 60 : 38,
            height: 1.06,
            fontWeight: FontWeight.w700,
            letterSpacing: wide ? -1.8 : -1,
          ),
        ),
        const SizedBox(height: 20),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            'Do the exercises your physiotherapist assigns, at home. '
            'PhysioAI follows your movement through your camera and gives '
            'you gentle feedback on your form, repetition by repetition.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.74),
              fontSize: wide ? 18 : 16,
              height: 1.55,
            ),
          ),
        ),
        const SizedBox(height: 32),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primaryMint,
                foregroundColor: AppColors.night,
                padding: const EdgeInsets.symmetric(
                  horizontal: 30,
                  vertical: 20,
                ),
                textStyle: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onPressed: () => context.go('/sign-in'),
              child: const Text('Get Started'),
            ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.4)),
                padding: const EdgeInsets.symmetric(
                  horizontal: 30,
                  vertical: 20,
                ),
                textStyle: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: () => context.go('/sign-in'),
              child: const Text('Sign In'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          "PhysioAI supports your physiotherapist's care. It does not "
          'diagnose conditions.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 13,
          ),
        ),
      ],
    );

    return HoloNight(
      horizon: wide ? 0.74 : 0.82,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: gutter),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1160),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 76,
                    child: Row(
                      children: [
                        const PhysioAiLogo(onDark: true),
                        const Spacer(),
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => context.go('/sign-in'),
                          child: const Text('Sign in'),
                        ),
                      ],
                    ),
                  ),
                  if (wide)
                    // As tall as whichever is taller, so large text settings
                    // push the page down instead of cutting the buttons off.
                    Row(
                      children: [
                        Expanded(
                          flex: 11,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 40),
                            child: intro,
                          ),
                        ),
                        const SizedBox(width: 24),
                        const Expanded(
                          flex: 10,
                          child: SizedBox(height: 640, child: _LiveStage()),
                        ),
                      ],
                    )
                  else ...[
                    const SizedBox(height: 28),
                    intro,
                    const SizedBox(height: 12),
                    const SizedBox(height: 540, child: _LiveStage()),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The hologram with the readings the app shows during a session.
class _LiveStage extends StatelessWidget {
  const _LiveStage();

  @override
  Widget build(BuildContext context) {
    const small = TextStyle(
      color: Colors.white,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    );
    final faint = TextStyle(
      color: Colors.white.withValues(alpha: 0.6),
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.1,
    );
    // On a phone the readings sit one under the other, clear of each other.
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          top: compact ? 96 : 12,
          bottom: 40,
          child: const HoloFigure(
            exercise: HoloExercise.squat,
            tone: HoloTone.correct,
            semanticLabel: 'A hologram of a person performing a squat',
          ),
        ),
        Positioned(
          left: 0,
          top: compact ? 0 : 36,
          child: HoloChip(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFF4ADE80),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                const Text('Tracking 33 body points', style: small),
              ],
            ),
          ),
        ),
        Positioned(
          right: 0,
          top: compact ? 52 : 24,
          child: HoloChip(
            padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const HoloGauge(value: 92, size: 58),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('FORM SCORE', style: faint),
                    const SizedBox(height: 2),
                    const Text('out of 100', style: small),
                  ],
                ),
              ],
            ),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 150,
          child: HoloChip(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('REPETITIONS', style: faint),
                const SizedBox(height: 2),
                const Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '8',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      TextSpan(text: '  of 12'),
                    ],
                  ),
                  style: small,
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 44,
          child: Center(
            child: HoloChip(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.auto_awesome_rounded,
                    color: AppColors.primaryMint,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  const Flexible(
                    child: Text(
                      'Good repetition. Keep your knees in line with your toes.',
                      style: small,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 14,
          child: Text(
            'An illustration of a live session',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.label, {this.onDark = false});

  final String label;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: onDark
            ? AppColors.primaryMint.withValues(alpha: 0.14)
            : AppColors.sand.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(100),
        border: Border.all(
          color: onDark
              ? AppColors.primaryMint.withValues(alpha: 0.4)
              : AppColors.clay.withValues(alpha: 0.25),
        ),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: onDark ? const Color(0xFF7BF1DD) : AppColors.clay,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.eyebrow,
    required this.title,
    required this.body,
  });

  final String eyebrow;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Eyebrow(eyebrow),
        const SizedBox(height: 16),
        Text(
          title,
          style: text.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Text(
            body,
            style: text.bodyLarge?.copyWith(
              color: AppColors.textMuted,
              height: 1.55,
            ),
          ),
        ),
        const SizedBox(height: 36),
      ],
    );
  }
}

/// Lays its children out in a row of equal columns, or stacked when narrow.
class _Columns extends StatelessWidget {
  const _Columns({required this.wide, required this.children});

  static const gap = 20.0;

  final bool wide;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0) const SizedBox(height: gap),
            child,
          ],
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0) const SizedBox(width: gap),
            Expanded(child: child),
          ],
        ],
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle(
          eyebrow: 'How it works',
          title: 'From your clinic to your living room',
          body:
              'Your physiotherapist stays in charge of your recovery. '
              'PhysioAI is how their plan reaches you between appointments.',
        ),
        _Columns(
          wide: wide,
          children: const [
            _Step(
              number: '01',
              icon: Icons.assignment_ind_outlined,
              title: 'Your physiotherapist assigns a plan',
              body:
                  'The exercises, sets and repetitions come from the '
                  'clinician who knows your recovery.',
            ),
            _Step(
              number: '02',
              icon: Icons.videocam_outlined,
              title: 'You exercise in front of your camera',
              body:
                  'The app checks that it can see you clearly, then follows '
                  'your joints as you move.',
            ),
            _Step(
              number: '03',
              icon: Icons.insights_rounded,
              title: 'You both see how it went',
              body:
                  'Every session gets a form score. Sessions that need a '
                  'closer look are sent to your physiotherapist.',
            ),
          ],
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.icon,
    required this.title,
    required this.body,
  });

  final String number;
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.divider),
        boxShadow: [
          BoxShadow(
            color: AppColors.navy.withValues(alpha: 0.06),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                number,
                style: const TextStyle(
                  color: AppColors.sand,
                  fontSize: 44,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.5,
                ),
              ),
              const Spacer(),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.primaryTint,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: AppColors.primary),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(title, style: text.titleLarge),
          const SizedBox(height: 8),
          Text(
            body,
            style: text.bodyMedium?.copyWith(
              color: AppColors.textMuted,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}

class _Exercises extends StatelessWidget {
  const _Exercises({required this.wide});

  final bool wide;

  static const _library = [
    (HoloExercise.armAbduction, 'Arm Abduction', 'Shoulder'),
    (HoloExercise.legAbduction, 'Leg Abduction', 'Hip'),
    (HoloExercise.lunge, 'Leg Lunge', 'Knee'),
    (HoloExercise.pushUp, 'Push-ups', 'Upper body'),
    (HoloExercise.squat, 'Squats', 'Whole body'),
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle(
          eyebrow: 'The exercise library',
          title: 'Five movements, each with its own checks',
          body:
              'Each exercise knows which joints matter and what good form '
              'looks like for it, so the feedback is about your movement, '
              'not a generic checklist.',
        ),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (final (exercise, name, area) in _library)
              SizedBox(
                width: wide ? 219 : 160,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AspectRatio(
                      aspectRatio: 0.82,
                      child: HoloStage(
                        dark: true,
                        radius: 22,
                        child: HoloFigure(
                          exercise: exercise,
                          tone: HoloTone.correct,
                          semanticLabel: 'A hologram performing $name',
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(name, style: text.titleMedium),
                    Text(
                      area,
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
    );
  }
}

class _Feedback extends StatelessWidget {
  const _Feedback({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle(
          eyebrow: 'Feedback you can act on',
          title: 'Three levels, so you know what matters',
          body:
              'Not every wobble is a problem. PhysioAI tells a small '
              'refinement apart from something that could hurt you.',
        ),
        _Columns(
          wide: wide,
          children: const [
            _Tier(
              color: AppColors.severityInfo,
              tint: AppColors.severityInfoBg,
              icon: Icons.lightbulb_outline_rounded,
              label: 'INFO',
              title: 'A small thing to refine',
              body: 'A short tip appears and your session carries on.',
            ),
            _Tier(
              color: AppColors.severityAmber,
              tint: AppColors.severityAmberBg,
              icon: Icons.warning_amber_rounded,
              label: 'AMBER',
              title: 'Form to correct',
              body:
                  'You are shown what to change, with a figure acting out '
                  'the correction.',
            ),
            _Tier(
              color: AppColors.severityRed,
              tint: AppColors.severityRedBg,
              icon: Icons.pause_circle_outline_rounded,
              label: 'RED',
              title: 'Stop and read',
              body:
                  'The session pauses until you have read the message, and '
                  'your physiotherapist is told.',
            ),
          ],
        ),
      ],
    );
  }
}

class _Tier extends StatelessWidget {
  const _Tier({
    required this.color,
    required this.tint,
    required this.icon,
    required this.label,
    required this.title,
    required this.body,
  });

  final Color color;
  final Color tint;
  final IconData icon;
  final String label;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border(left: BorderSide(color: color, width: 5)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.1),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: tint,
              borderRadius: BorderRadius.circular(100),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(title, style: text.titleLarge),
          const SizedBox(height: 6),
          Text(
            body,
            style: text.bodyMedium?.copyWith(
              color: AppColors.textMuted,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}

/// The last word: privacy, and the way in.
class _Closing extends StatelessWidget {
  const _Closing({required this.wide, required this.gutter});

  final bool wide;
  final double gutter;

  @override
  Widget build(BuildContext context) {
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.lock_outline_rounded, color: AppColors.sand, size: 32),
        const SizedBox(height: 16),
        Text(
          'Your video never leaves your device.',
          style: TextStyle(
            color: Colors.white,
            fontSize: wide ? 34 : 26,
            height: 1.15,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Text(
            'The camera picture is read on your own device and thrown away. '
            'Only the positions of your joints are used, and what is kept is '
            'shared with your physiotherapist and nobody else.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),
              fontSize: 16,
              height: 1.55,
            ),
          ),
        ),
      ],
    );
    final action = FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.primaryDark,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
      onPressed: () => context.go('/sign-in'),
      icon: const Icon(Icons.arrow_forward_rounded),
      label: const Text('Open PhysioAI'),
    );
    return HoloNight(
      horizon: 0.55,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 72),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1160),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide)
                  Row(
                    children: [
                      Expanded(child: words),
                      const SizedBox(width: 32),
                      action,
                    ],
                  )
                else ...[
                  words,
                  const SizedBox(height: 28),
                  Align(alignment: Alignment.centerLeft, child: action),
                ],
                const SizedBox(height: 56),
                Divider(color: Colors.white.withValues(alpha: 0.12), height: 1),
                const SizedBox(height: 20),
                Text(
                  'PhysioAI · A final year project at FCIT, University of the '
                  'Punjab. It supports the care of a physiotherapist and is '
                  'not a medical device.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
