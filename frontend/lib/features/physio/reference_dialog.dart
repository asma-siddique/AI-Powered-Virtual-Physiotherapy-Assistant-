import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../progress/session_widgets.dart';
import '../shell/page_widgets.dart';
import '../session/session_records.dart';
import 'physio_repository.dart';

/// A patient's own references (one per exercise at most) and their recent
/// sessions, from which two repetitions the physiotherapist saw done
/// correctly can be made the reference. Sessions of an exercise with a
/// reference are judged by how close each repetition comes to it.
class ReferenceDialog extends ConsumerStatefulWidget {
  const ReferenceDialog({super.key, required this.patient});

  final PatientSummary patient;

  @override
  ConsumerState<ReferenceDialog> createState() => _ReferenceDialogState();
}

class _ReferenceDialogState extends ConsumerState<ReferenceDialog> {
  String? _error;

  String get _patientId => widget.patient.id;

  void _refresh() {
    ref.invalidate(patientReferencesProvider(_patientId));
    ref.invalidate(physioPatientSessionsProvider(_patientId));
  }

  Future<void> _retire(ExerciseReference reference) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop using the ${reference.exercise.name} reference?'),
        content: const Text(
          'Later sessions of this exercise are scored by the usual model '
          'again. The reference is kept on record.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-retire-reference'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop using it'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    try {
      await ref
          .read(physioRepositoryProvider)
          .retireReference(_patientId, reference.id);
      setState(() => _error = null);
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    }
    _refresh();
  }

  void _open(SessionBrief session) => showSessionDetail(
    context,
    patientName: widget.patient.fullName,
    load: () => ref.read(physioRepositoryProvider).session(session.id),
    onMakeReference: (_, ids) async {
      await ref.read(physioRepositoryProvider).setReference(_patientId, ids);
      _refresh();
    },
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final references = ref.watch(patientReferencesProvider(_patientId));
    final sessions = ref.watch(physioPatientSessionsProvider(_patientId));
    return Dialog(
      key: const Key('reference-dialog'),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 760),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      "${widget.patient.fullName}'s reference",
                      style: text.titleLarge,
                    ),
                  ),
                  IconButton(
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
                      'Each patient makes mistakes in their own way, so a '
                      "repetition is judged best against the patient's own "
                      'correct ones. Open a session you supervised, tick two '
                      'repetitions you saw done correctly, and later sessions '
                      'of that exercise are judged against them.',
                      style: text.bodyMedium,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      InlineBanner(message: _error!),
                    ],
                    const SizedBox(height: 16),
                    Text('In use', style: text.titleMedium),
                    const SizedBox(height: 4),
                    AsyncSection(
                      value: references,
                      onRetry: _refresh,
                      builder: (list) => list.isEmpty
                          ? Text(
                              'No reference yet: sessions are scored by the '
                              'usual model.',
                              key: const Key('no-references'),
                              style: text.bodyMedium?.copyWith(
                                color: AppColors.textMuted,
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final reference in list)
                                  _ReferenceRow(
                                    reference: reference,
                                    onRetire: () => _retire(reference),
                                  ),
                              ],
                            ),
                    ),
                    const SizedBox(height: 20),
                    Text('Sessions', style: text.titleMedium),
                    const SizedBox(height: 4),
                    AsyncSection(
                      value: sessions,
                      onRetry: _refresh,
                      builder: (list) => list.isEmpty
                          ? Text(
                              'No finished sessions yet.',
                              style: text.bodyMedium?.copyWith(
                                color: AppColors.textMuted,
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final session in list)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: SessionCard(
                                      session: session,
                                      onOpen: () => _open(session),
                                    ),
                                  ),
                              ],
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

class _ReferenceRow extends StatelessWidget {
  const _ReferenceRow({required this.reference, required this.onRetire});

  final ExerciseReference reference;
  final VoidCallback onRetire;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final from = reference.repetitions
        .map((r) => 'set ${r.setNumber} rep ${r.repNumber}')
        .join(' and ');
    final started = reference.repetitions.isEmpty
        ? null
        : reference.repetitions.first.sessionStartedAt;
    return Container(
      key: Key('reference-${reference.exercise.slug}'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(reference.exercise.name, style: text.titleSmall),
                Text(
                  'From $from'
                  '${started == null ? '' : ' of the session on ${formatDate(started)}'}'
                  '  ·  set by ${reference.createdBy.fullName}  ·  '
                  'judged ${reference.sessionsJudged} '
                  'session${reference.sessionsJudged == 1 ? '' : 's'}',
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          TextButton(
            key: Key('retire-reference-${reference.exercise.slug}'),
            onPressed: onRetire,
            child: const Text('Stop using'),
          ),
        ],
      ),
    );
  }
}
