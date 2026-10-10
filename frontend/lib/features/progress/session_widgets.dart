import 'package:flutter/material.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../session/repetitions.dart';
import '../session/session_records.dart';

/// A session's form score, or a plain statement that it has none. A missing
/// score is never drawn as 0.
class ScoreBadge extends StatelessWidget {
  const ScoreBadge({super.key, required this.score, this.size = 56});

  final int? score;
  final double size;

  static Color colorFor(int score) => score >= 85
      ? AppColors.success
      : score >= 60
      ? AppColors.warning
      : AppColors.error;

  @override
  Widget build(BuildContext context) {
    final value = score;
    final color = value == null ? AppColors.textMuted : colorFor(value);
    return Semantics(
      label: value == null ? 'Not scored' : 'Form score $value out of 100',
      excludeSemantics: true,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 3),
        ),
        child: Text(
          value == null ? '–' : '$value',
          style: TextStyle(
            fontSize: size * 0.36,
            fontWeight: FontWeight.w700,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// How many repetitions fell in each tier, as pills. Tiers with none are
/// left out.
class TierBreakdown extends StatelessWidget {
  const TierBreakdown({super.key, required this.totals});

  final SessionTotals totals;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (totals.ok > 0) Pill.success('${totals.ok} good'),
        if (totals.info > 0)
          Pill(
            '${totals.info} to refine',
            foreground: AppColors.primaryDark,
            background: AppColors.primaryTint,
          ),
        if (totals.amber > 0) Pill.warning('${totals.amber} to work on'),
        if (totals.red > 0)
          Pill(
            '${totals.red} paused for safety',
            foreground: AppColors.error,
            background: AppColors.errorTint,
          ),
      ],
    );
  }
}

String repetitionCount(int count) =>
    count == 1 ? '1 repetition' : '$count repetitions';

/// One session in a list.
class SessionCard extends StatelessWidget {
  const SessionCard({
    super.key,
    required this.session,
    required this.onOpen,
    this.heading,
    this.extra = const [],
  });

  final SessionBrief session;
  final VoidCallback onOpen;

  /// Shown above the exercise name: the patient, in a physiotherapist's list.
  final String? heading;

  /// Further pills, such as why the session was flagged.
  final List<Widget> extra;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AppCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        key: Key('open-session-${session.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ScoreBadge(score: session.formScore),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (heading != null)
                      Text(
                        heading!,
                        style: text.bodySmall?.copyWith(
                          color: AppColors.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    Text(session.exercise.name, style: text.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '${formatDateTime(session.startedAt)}  ·  '
                      '${repetitionCount(session.totals.repetitions)}  ·  '
                      '${formatDuration(session.durationSeconds)}',
                      style: text.bodySmall?.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ...extra,
                        if (session.isUnderWay)
                          const Pill.neutral('In progress'),
                        if (session.wasLeftOpen)
                          const Pill.neutral('Not finished'),
                        if (session.formScore == null && !session.isUnderWay)
                          const Pill.neutral('Not scored'),
                        TierBreakdown(totals: session.totals),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.border),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens one session in full. [load] fetches it; [footer] adds actions for
/// whoever is looking, such as marking it reviewed.
Future<void> showSessionDetail(
  BuildContext context, {
  required Future<SessionDetail> Function() load,
  String? patientName,
  Widget Function(BuildContext context, SessionDetail session)? footer,
}) => showDialog<void>(
  context: context,
  builder: (context) => _SessionDetailDialog(
    load: load,
    patientName: patientName,
    footer: footer,
  ),
);

class _SessionDetailDialog extends StatefulWidget {
  const _SessionDetailDialog({
    required this.load,
    this.patientName,
    this.footer,
  });

  final Future<SessionDetail> Function() load;
  final String? patientName;
  final Widget Function(BuildContext context, SessionDetail session)? footer;

  @override
  State<_SessionDetailDialog> createState() => _SessionDetailDialogState();
}

class _SessionDetailDialogState extends State<_SessionDetailDialog> {
  late Future<SessionDetail> _session = widget.load();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('session-detail'),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 760),
        child: FutureBuilder<SessionDetail>(
          future: _session,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              final error = snapshot.error;
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InlineBanner(
                      message: error is ApiException
                          ? error.message
                          : 'Something went wrong. Please try again.',
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Close'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () =>
                              setState(() => _session = widget.load()),
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }
            final session = snapshot.data;
            if (session == null) {
              return const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return _detail(context, session);
          },
        ),
      ),
    );
  }

  Widget _detail(BuildContext context, SessionDetail session) {
    final text = Theme.of(context).textTheme;
    final sets = <int, List<RepetitionDetail>>{};
    for (final repetition in session.repetitions) {
      sets.putIfAbsent(repetition.setNumber, () => []).add(repetition);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ScoreBadge(score: session.formScore, size: 64),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.patientName != null)
                      Text(
                        widget.patientName!,
                        style: text.bodySmall?.copyWith(
                          color: AppColors.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    Text(session.exercise.name, style: text.titleLarge),
                    const SizedBox(height: 2),
                    Text(
                      '${formatDateTime(session.startedAt)}  ·  '
                      '${formatDuration(session.durationSeconds)}',
                      style: text.bodySmall?.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                    Text(
                      'Prescribed: ${session.sets} sets × ${session.reps} reps',
                      style: text.bodySmall?.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const Key('close-session-detail'),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  session.formScore == null
                      ? session.isUnderWay
                            ? 'This session is still in progress, so it has no score yet.'
                            : 'There was nothing to score in this session.'
                      : 'Form score ${session.formScore} out of 100, from '
                            '${repetitionCount(session.totals.repetitions)}.',
                  key: const Key('detail-score'),
                  style: text.bodyLarge,
                ),
                const SizedBox(height: 12),
                TierBreakdown(totals: session.totals),
                if (session.wasLeftOpen) ...[
                  const SizedBox(height: 12),
                  const InlineBanner(
                    tone: BannerTone.info,
                    message:
                        'This session was not ended in the app. It was closed '
                        'when the next one started.',
                  ),
                ],
                if (session.repetitions.isEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    'No repetitions were recorded.',
                    style: text.bodyMedium?.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
                for (final entry in sets.entries) ...[
                  const SizedBox(height: 20),
                  Text('Set ${entry.key}', style: text.titleMedium),
                  const SizedBox(height: 4),
                  for (final repetition in entry.value)
                    _RepetitionRow(repetition: repetition),
                ],
                if (session.scoringVersion != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Scored with ${session.scoringVersion}.',
                    style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (widget.footer != null) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: widget.footer!(context, session),
          ),
        ],
      ],
    );
  }
}

class _RepetitionRow extends StatelessWidget {
  const _RepetitionRow({required this.repetition});

  final RepetitionDetail repetition;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (label, foreground, background) = switch (repetition.tier) {
      FeedbackTier.ok => ('Good', AppColors.success, AppColors.successTint),
      FeedbackTier.info => (
        'Refine',
        AppColors.primaryDark,
        AppColors.primaryTint,
      ),
      FeedbackTier.amber => (
        'Work on',
        AppColors.warning,
        AppColors.warningTint,
      ),
      FeedbackTier.red => ('Paused', AppColors.error, AppColors.errorTint),
    };
    return Container(
      key: Key('detail-rep-${repetition.setNumber}-${repetition.repNumber}'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Text('${repetition.repNumber}', style: text.titleSmall),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Pill(label, foreground: foreground, background: background),
                if (repetition.feedback.isNotEmpty ||
                    repetition.unmeasured.isNotEmpty)
                  const SizedBox(height: 6),
                for (final item in repetition.feedback)
                  Text(
                    '${item.label}: ${item.message}',
                    style: text.bodyMedium,
                  ),
                if (repetition.unmeasured.isNotEmpty)
                  Text(
                    'Not in view: ${repetition.unmeasured.join(', ').replaceAll('_', ' ')}',
                    style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One scored session on the trend.
typedef TrendPoint = ({DateTime at, int score});

/// Form score across sessions. Only sessions that have a score are plotted,
/// at their own date: nothing is drawn for a day without one.
class TrendChart extends StatelessWidget {
  const TrendChart({super.key, required this.points, this.height = 220});

  /// Oldest first.
  final List<TrendPoint> points;
  final double height;

  @override
  Widget build(BuildContext context) {
    final first = points.isEmpty ? null : points.first;
    final last = points.isEmpty ? null : points.last;
    return Semantics(
      label: points.isEmpty
          ? 'No scored sessions to plot.'
          : 'Form score trend: ${points.length} scored '
                '${points.length == 1 ? 'session' : 'sessions'}, from '
                '${first!.score} on ${formatDate(first.at)} to ${last!.score} '
                'on ${formatDate(last.at)}.',
      child: SizedBox(
        height: height,
        child: CustomPaint(
          painter: _TrendPainter(
            points,
            Theme.of(context).textTheme.bodySmall!,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.points, this.labelStyle);

  final List<TrendPoint> points;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 32.0, bottom = 22.0, top = 8.0, right = 12.0;
    final plot = Rect.fromLTRB(
      left,
      top,
      size.width - right,
      size.height - bottom,
    );
    final grid = Paint()
      ..color = AppColors.divider
      ..strokeWidth = 1;
    double y(num score) => plot.bottom - plot.height * score / 100;

    for (final mark in const [0, 25, 50, 75, 100]) {
      canvas.drawLine(
        Offset(plot.left, y(mark)),
        Offset(plot.right, y(mark)),
        grid,
      );
      final painter = TextPainter(
        text: TextSpan(
          text: '$mark',
          style: labelStyle.copyWith(color: AppColors.textMuted, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(plot.left - painter.width - 6, y(mark) - painter.height / 2),
      );
    }
    if (points.isEmpty) return;

    final start = points.first.at.millisecondsSinceEpoch;
    final span = points.last.at.millisecondsSinceEpoch - start;
    double x(DateTime at) => span == 0
        ? plot.center.dx
        : plot.left + plot.width * (at.millisecondsSinceEpoch - start) / span;

    final line = Paint()
      ..color = AppColors.primary
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    for (final (i, point) in points.indexed) {
      final at = Offset(x(point.at), y(point.score));
      i == 0 ? path.moveTo(at.dx, at.dy) : path.lineTo(at.dx, at.dy);
    }
    canvas.drawPath(path, line);
    for (final point in points) {
      final at = Offset(x(point.at), y(point.score));
      canvas.drawCircle(at, 5, Paint()..color = AppColors.surface);
      canvas.drawCircle(at, 4, Paint()..color = AppColors.primary);
    }

    void dateLabel(DateTime at, {required bool alignRight}) {
      final painter = TextPainter(
        text: TextSpan(
          text: formatDate(at),
          style: labelStyle.copyWith(color: AppColors.textMuted, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        Offset(
          alignRight ? plot.right - painter.width : plot.left,
          plot.bottom + 6,
        ),
      );
    }

    dateLabel(points.first.at, alignRight: false);
    if (span != 0) dateLabel(points.last.at, alignRight: true);
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.points != points;
}
