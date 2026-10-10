import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../progress/session_widgets.dart';
import '../session/session_records.dart';
import '../shell/page_widgets.dart';
import 'physio_repository.dart';

/// "Flagged Sessions": sessions that had a RED repetition or a low score,
/// waiting until the physiotherapist marks each one reviewed.
class FlaggedSessionsPage extends ConsumerStatefulWidget {
  const FlaggedSessionsPage({super.key});

  @override
  ConsumerState<FlaggedSessionsPage> createState() =>
      _FlaggedSessionsPageState();
}

class _FlaggedSessionsPageState extends ConsumerState<FlaggedSessionsPage> {
  bool _reviewed = false;

  String get _state => _reviewed ? 'reviewed' : 'unreviewed';

  void _refresh() {
    ref.invalidate(flaggedSessionsProvider('unreviewed'));
    ref.invalidate(flaggedSessionsProvider('reviewed'));
  }

  void _open(FlaggedSession entry) => showSessionDetail(
    context,
    patientName: entry.patient.fullName,
    load: () => ref.read(physioRepositoryProvider).session(entry.session.id),
    footer: (dialogContext, session) =>
        _ReviewFooter(session: session, onReviewed: _refresh),
  );

  @override
  Widget build(BuildContext context) {
    final flagged = ref.watch(flaggedSessionsProvider(_state));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageIntro(
          title: 'Flagged Sessions',
          subtitle:
              'Sessions paused for safety or with a low form score. '
              'Each stays here until you mark it reviewed.',
          action: SegmentedButton<bool>(
            key: const Key('flagged-state'),
            segments: const [
              ButtonSegment(value: false, label: Text('To review')),
              ButtonSegment(value: true, label: Text('Reviewed')),
            ],
            selected: {_reviewed},
            showSelectedIcon: false,
            onSelectionChanged: (selected) =>
                setState(() => _reviewed = selected.single),
          ),
        ),
        AsyncSection(
          value: flagged,
          onRetry: _refresh,
          builder: (entries) => entries.isEmpty
              ? AppCard(
                  child: EmptyState(
                    icon: _reviewed
                        ? Icons.fact_check_outlined
                        : Icons.flag_outlined,
                    message: _reviewed
                        ? 'You have not reviewed any flagged sessions yet.'
                        : 'Nothing is waiting for review.\n'
                              'A session appears here when it is paused for '
                              'safety or scores low.',
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final entry in entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: SessionCard(
                          session: entry.session,
                          heading: entry.patient.fullName,
                          onOpen: () => _open(entry),
                          extra: [
                            for (final reason in entry.reasons)
                              Pill(
                                reason,
                                icon: Icons.flag_rounded,
                                foreground: AppColors.error,
                                background: AppColors.errorTint,
                              ),
                            if (entry.session.isReviewed)
                              Pill.success(
                                entry.reviewedBy == null
                                    ? 'Reviewed'
                                    : 'Reviewed by ${entry.reviewedBy!.fullName}',
                                icon: Icons.check_rounded,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ReviewFooter extends ConsumerStatefulWidget {
  const _ReviewFooter({required this.session, required this.onReviewed});

  final SessionDetail session;
  final VoidCallback onReviewed;

  @override
  ConsumerState<_ReviewFooter> createState() => _ReviewFooterState();
}

class _ReviewFooterState extends ConsumerState<_ReviewFooter> {
  bool _busy = false;
  String? _error;

  Future<void> _review() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(physioRepositoryProvider)
          .markSessionReviewed(widget.session.id);
      widget.onReviewed();
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final reviewedAt = widget.session.reviewedAt;
    if (reviewedAt != null) {
      return Text(
        'Reviewed on ${formatDateTime(reviewedAt)}.',
        key: const Key('reviewed-note'),
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: AppColors.success),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error != null) ...[
          InlineBanner(key: const Key('review-error'), message: _error!),
          const SizedBox(height: 12),
        ],
        BusyButton(
          key: const Key('mark-reviewed'),
          label: 'Mark as reviewed',
          busy: _busy,
          onPressed: _review,
        ),
      ],
    );
  }
}
