import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// The PhysioAI mark and wordmark, identical everywhere it appears.
class PhysioAiLogo extends StatelessWidget {
  const PhysioAiLogo({super.key, this.size = 32, this.onDark = false});

  final double size;

  /// White wordmark, for dark backgrounds.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: AppColors.cardGradient,
            borderRadius: BorderRadius.circular(size * 0.3),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryMint.withValues(alpha: 0.35),
                blurRadius: size * 0.4,
                offset: Offset(0, size * 0.1),
              ),
            ],
          ),
          child: Icon(
            Icons.accessibility_new_rounded,
            color: Colors.white,
            size: size * 0.62,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          'PhysioAI',
          style: TextStyle(
            fontSize: size * 0.62,
            fontWeight: FontWeight.w700,
            color: onDark ? Colors.white : AppColors.text,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }
}

/// White card on the canvas: 16px radius, hairline border, soft shadow.
/// An [accent] adds a 4px coloured border on the left.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
    this.color,
    this.accent,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final body = Padding(padding: padding, child: child);
    return Container(
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        border: Border.all(color: AppColors.divider),
        boxShadow: cardShadow,
      ),
      clipBehavior: accent == null ? Clip.none : Clip.antiAlias,
      child: accent == null
          ? body
          : DecoratedBox(
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: accent!, width: 4)),
              ),
              child: body,
            ),
    );
  }
}

/// Small pill with tinted background, used for roles and statuses.
class Pill extends StatelessWidget {
  const Pill(
    this.label, {
    super.key,
    required this.foreground,
    required this.background,
    this.icon,
  });

  const Pill.success(this.label, {super.key, this.icon})
    : foreground = AppColors.success,
      background = AppColors.successTint;

  const Pill.warning(this.label, {super.key, this.icon})
    : foreground = AppColors.warning,
      background = AppColors.warningTint;

  const Pill.neutral(this.label, {super.key, this.icon})
    : foreground = AppColors.textMuted,
      background = AppColors.divider;

  final String label;
  final Color foreground;
  final Color background;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: foreground,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

enum BannerTone { error, warning, info, success }

/// Inline message inside a form or card.
class InlineBanner extends StatelessWidget {
  const InlineBanner({
    super.key,
    required this.message,
    this.tone = BannerTone.error,
    this.icon,
  });

  final String message;
  final BannerTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final (foreground, background, defaultIcon) = switch (tone) {
      BannerTone.error => (
        AppColors.error,
        AppColors.errorTint,
        Icons.error_outline_rounded,
      ),
      BannerTone.warning => (
        AppColors.warning,
        AppColors.warningTint,
        Icons.lock_clock_outlined,
      ),
      BannerTone.info => (
        AppColors.info,
        AppColors.infoTint,
        Icons.info_outline_rounded,
      ),
      BannerTone.success => (
        AppColors.success,
        AppColors.successTint,
        Icons.check_circle_outline_rounded,
      ),
    };
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(color: foreground.withValues(alpha: 0.14)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon ?? defaultIcon, size: 20, color: foreground),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(fontSize: 14, height: 1.43, color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A form field with its label above and optional helper text below, as the
/// design system requires (never placeholder-only).
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.child,
    this.helper,
  });

  final String label;
  final Widget child;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.text,
          ),
        ),
        const SizedBox(height: 6),
        child,
        if (helper != null) ...[
          const SizedBox(height: 6),
          Text(
            helper!,
            style: const TextStyle(
              fontSize: 13,
              height: 1.4,
              color: AppColors.textMuted,
            ),
          ),
        ],
      ],
    );
  }
}

/// Password input with a show/hide toggle.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    this.validator,
    this.hintText,
    this.textInputAction,
    this.onSubmitted,
    this.autofillHints,
    this.fieldKey,
  });

  final TextEditingController controller;
  final FormFieldValidator<String>? validator;
  final String? hintText;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final Iterable<String>? autofillHints;
  final Key? fieldKey;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      key: widget.fieldKey,
      controller: widget.controller,
      obscureText: _hidden,
      validator: widget.validator,
      textInputAction: widget.textInputAction,
      onFieldSubmitted: widget.onSubmitted,
      autofillHints: widget.autofillHints,
      decoration: InputDecoration(
        hintText: widget.hintText,
        suffixIcon: IconButton(
          tooltip: _hidden ? 'Show password' : 'Hide password',
          icon: Icon(
            _hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            size: 20,
          ),
          onPressed: () => setState(() => _hidden = !_hidden),
        ),
      ),
    );
  }
}

/// Filled button that shows a spinner and blocks repeat presses while busy.
class BusyButton extends StatelessWidget {
  const BusyButton({
    super.key,
    required this.label,
    required this.busy,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final bool busy;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    // The gradient sits behind a transparent FilledButton, so the button
    // keeps all of its own behaviour.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        gradient: enabled || busy ? AppColors.heroGradient : null,
        color: enabled || busy ? null : AppColors.disabled,
        borderRadius: BorderRadius.circular(100),
        boxShadow: enabled ? AppTheme.elevatedShadow : null,
      ),
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
          disabledForegroundColor: Colors.white,
          foregroundColor: Colors.white,
          shadowColor: Colors.transparent,
        ),
        child: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18),
                    const SizedBox(width: 8),
                  ],
                  Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
                ],
              ),
      ),
    );
  }
}

/// Centred icon, one sentence, optional action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.action,
    this.title,
    this.illustration,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  /// A heading above the message, such as "All caught up!".
  final String? title;

  /// Drawn instead of the icon.
  final Widget? illustration;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (illustration != null)
            illustration!
          else
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.primaryTint, Color(0xFFD5EEF3)],
                ),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: AppTheme.glowShadow,
              ),
              child: Icon(icon, color: AppColors.primary, size: 30),
            ),
          const SizedBox(height: 12),
          if (title != null) ...[
            Text(
              title!,
              textAlign: TextAlign.center,
              style: AppTheme.headingLarge,
            ),
            const SizedBox(height: 6),
          ],
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              height: 1.45,
              color: AppColors.textMuted,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

String formatDate(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = value.toLocal();
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

String formatDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${formatDate(local)}, ${two(local.hour)}:${two(local.minute)}';
}
