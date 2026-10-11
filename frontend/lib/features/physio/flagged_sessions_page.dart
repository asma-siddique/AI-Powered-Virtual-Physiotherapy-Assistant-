import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/animations.dart';
import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
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
                    title: _reviewed ? null : 'All caught up!',
                    illustration: _reviewed
                        ? null
                        : Container(
                            width: 96,
                            height: 96,
                            decoration: const BoxDecoration(
                              gradient: AppColors.heroGradient,
                              shape: BoxShape.circle,
                              boxShadow: AppTheme.elevatedShadow,
                            ),
                            child: const CelebrationCheck(size: 96),
                          ),
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

  late final _note = TextEditingController(
    text: widget.session.clinicianNote ?? '',
  );
  bool _savingNote = false;
  bool _noteSaved = false;
  String? _noteError;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _saveNote() async {
    setState(() {
      _savingNote = true;
      _noteSaved = false;
      _noteError = null;
    });
    try {
      await ref
          .read(physioRepositoryProvider)
          .saveSessionNote(widget.session.id, _note.text.trim());
      if (!mounted) return;
      setState(() {
        _savingNote = false;
        _noteSaved = true;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _savingNote = false;
        _noteError = error.message;
      });
    }
  }

  Widget _noteEditor() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      TextField(
        key: const Key('clinician-note'),
        controller: _note,
        maxLength: 2000,
        minLines: 1,
        maxLines: 3,
        onChanged: (_) => setState(() => _noteSaved = false),
        decoration: const InputDecoration(
          labelText: 'Your note on this session',
          hintText: 'Seen by the patient and included in reports',
        ),
      ),
      if (_noteError != null)
        InlineBanner(key: const Key('note-error'), message: _noteError!),
      Align(
        alignment: Alignment.centerLeft,
        child: _noteSaved
            ? Text(
                'Note saved.',
                key: const Key('note-saved'),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.success),
              )
            : TextButton.icon(
                key: const Key('save-note'),
                onPressed: _savingNote ? null : _saveNote,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('Save note'),
              ),
      ),
      const SizedBox(height: 8),
    ],
  );

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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _noteEditor(),
          Text(
            'Reviewed on ${formatDateTime(reviewedAt)}.',
            key: const Key('reviewed-note'),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppColors.success),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _noteEditor(),
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
