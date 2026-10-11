import 'package:flutter/material.dart';

import '../animations.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Severity of a piece of feedback, as the patient sees it.
enum Severity {
  red,
  amber,
  info,
  good;

  Color get color => switch (this) {
    red => AppColors.severityRed,
    amber => AppColors.severityAmber,
    info => AppColors.severityInfo,
    good => AppColors.severityGreen,
  };

  Color get background => switch (this) {
    red => AppColors.severityRedBg,
    amber => AppColors.severityAmberBg,
    info => AppColors.severityInfoBg,
    good => AppColors.severityGreenBg,
  };

  IconData get icon => switch (this) {
    red => Icons.front_hand_rounded,
    amber => Icons.warning_amber_rounded,
    info => Icons.lightbulb_outline_rounded,
    good => Icons.check_circle_rounded,
  };
}

/// The main call to action: a tall teal-gradient pill with a soft glow.
///
/// A [FilledButton] sits inside, so it behaves (focus, semantics, disabled
/// state) exactly like every other button in the app.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
    this.icon,
    this.trailingIcon,
    this.buttonKey,
    this.expand = false,
    this.gradient = AppColors.heroGradient,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;
  final IconData? trailingIcon;

  /// Key for the inner [FilledButton], for finding it in tests.
  final Key? buttonKey;
  final bool expand;
  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final button = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        gradient: enabled || loading ? gradient : null,
        color: enabled || loading ? null : AppColors.disabled,
        borderRadius: BorderRadius.circular(27),
        boxShadow: enabled ? AppTheme.elevatedShadow : null,
      ),
      child: FilledButton(
        key: buttonKey,
        onPressed: enabled ? onPressed : null,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 54),
          backgroundColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
          disabledForegroundColor: Colors.white,
          shadowColor: Colors.transparent,
          foregroundColor: Colors.white,
          textStyle: AppTheme.buttonText,
        ),
        child: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 20),
                    const SizedBox(width: 10),
                  ],
                  Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
                  if (trailingIcon != null) ...[
                    const SizedBox(width: 10),
                    Icon(trailingIcon, size: 20),
                  ],
                ],
              ),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// Outlined teal pill, the same size as [PrimaryButton].
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expand = false,
    this.onDark = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expand;

  /// White outline and text, for dark or gradient backgrounds.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final color = onDark ? Colors.white : AppColors.primary;
    final button = OutlinedButton(
      onPressed: onPressed,
      style:
          OutlinedButton.styleFrom(
            minimumSize: const Size(0, 54),
            foregroundColor: color,
            side: BorderSide(color: color.withValues(alpha: 0.9), width: 1.5),
            backgroundColor: Colors.transparent,
          ).copyWith(
            overlayColor: WidgetStatePropertyAll(
              onDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : AppColors.primaryTint,
            ),
          ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20),
            const SizedBox(width: 10),
          ],
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// White card with a soft shadow. An [accent] adds the 4px severity border
/// on the left; a [header] adds a gradient strip across the top.
class PhysioCard extends StatelessWidget {
  const PhysioCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppTheme.paddingM),
    this.accent,
    this.header,
    this.headerGradient = AppColors.cardGradient,
    this.color = AppColors.surface,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? accent;
  final Widget? header;
  final Gradient headerGradient;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    Widget body = Padding(padding: padding, child: child);
    if (onTap != null) {
      body = InkWell(onTap: onTap, child: body);
    }
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        boxShadow: AppTheme.cardShadow,
        border: Border.all(color: AppColors.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (header != null)
              DecoratedBox(
                decoration: BoxDecoration(gradient: headerGradient),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.paddingM,
                    vertical: 12,
                  ),
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(color: Colors.white),
                    child: IconTheme.merge(
                      data: const IconThemeData(color: Colors.white),
                      child: header!,
                    ),
                  ),
                ),
              ),
            if (accent != null)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(width: 4, color: accent),
                    Expanded(child: body),
                  ],
                ),
              )
            else
              body,
          ],
        ),
      ),
    );
  }
}

/// Pill with a coloured dot: RED, AMBER, INFO or GOOD.
class SeverityBadge extends StatelessWidget {
  const SeverityBadge({
    super.key,
    required this.severity,
    required this.label,
    this.wide = false,
  });

  final Severity severity;
  final String label;

  /// Full width, for the last-feedback slot.
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: severity.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: severity.color.withValues(alpha: 0.5),
                blurRadius: 6,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.labelBold.copyWith(color: severity.color),
          ),
        ),
      ],
    );
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: severity.background,
        borderRadius: BorderRadius.circular(AppTheme.radiusFull),
      ),
      child: content,
    );
  }
}

/// Small number card: a large coloured value over a quiet label.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    this.color = AppColors.primary,
    this.icon,
    this.trailing,
    this.onDark = false,
    this.valueKey,
  });

  final String value;
  final String label;
  final Color color;
  final IconData? icon;

  /// Beside the value: a trend arrow or a flame.
  final Widget? trailing;

  /// Glass style for gradient backgrounds.
  final bool onDark;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        color: onDark ? Colors.white.withValues(alpha: 0.1) : AppColors.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        border: Border.all(
          color: onDark
              ? Colors.white.withValues(alpha: 0.16)
              : AppColors.border,
        ),
        boxShadow: onDark ? null : AppTheme.cardShadow,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: onDark ? Colors.white70 : color),
            const SizedBox(height: 8),
          ],
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  value,
                  key: valueKey,
                  style: AppTheme.statNumber.copyWith(
                    color: onDark ? Colors.white : color,
                    fontSize: 28,
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 4), trailing!],
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.bodyMedium.copyWith(
              color: onDark ? Colors.white70 : AppColors.textMuted,
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// A thin rounded progress bar: teal fill on a grey track.
class ProgressTrack extends StatelessWidget {
  const ProgressTrack({
    super.key,
    required this.value,
    this.color = AppColors.primary,
    this.track = AppColors.divider,
    this.height = 6,
  });

  final double value;
  final Color color;
  final Color track;
  final double height;

  @override
  Widget build(BuildContext context) {
    final target = value.clamp(0.0, 1.0);
    Widget bar(double v) => ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: track),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: v,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [color, Color.lerp(color, Colors.white, 0.3)!],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (!Motion.of(context)) return bar(target);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => bar(v),
    );
  }
}

/// A heading with an optional action on the right.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.action, this.icon});

  final String title;
  final Widget? action;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.primaryTint,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: AppColors.primary),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        ?action,
      ],
    );
  }
}

/// A rounded square with a gradient and a glyph: the visual anchor of
/// cards and list rows.
class GlyphTile extends StatelessWidget {
  const GlyphTile({
    super.key,
    required this.icon,
    this.size = 44,
    this.gradient = AppColors.heroGradient,
  });

  final IconData icon;
  final double size;
  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: AppTheme.elevatedShadow,
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.5),
    );
  }
}
