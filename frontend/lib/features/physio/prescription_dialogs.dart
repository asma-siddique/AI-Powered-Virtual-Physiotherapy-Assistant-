import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../exercises/exercise_models.dart';
import '../shell/page_widgets.dart';
import 'physio_repository.dart';

/// Adjusts one exercise of a patient's current plan. Closes with the plan as
/// saved, or with nothing when it was cancelled or nothing was changed.
class EditPrescriptionDialog extends ConsumerStatefulWidget {
  const EditPrescriptionDialog({
    super.key,
    required this.patient,
    required this.plan,
    required this.item,
  });

  final PatientSummary patient;
  final ExercisePlan plan;
  final PlanItem item;

  @override
  ConsumerState<EditPrescriptionDialog> createState() =>
      _EditPrescriptionDialogState();
}

class _EditPrescriptionDialogState
    extends ConsumerState<EditPrescriptionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _sets = TextEditingController(text: '${widget.item.sets}');
  late final _reps = TextEditingController(text: '${widget.item.reps}');
  late final _note = TextEditingController(text: widget.item.note);
  late int _rest = widget.item.restSeconds;
  late Difficulty _difficulty = widget.item.difficulty;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _sets.dispose();
    _reps.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _unchanged {
    final item = widget.item;
    return int.tryParse(_sets.text) == item.sets &&
        int.tryParse(_reps.text) == item.reps &&
        _rest == item.restSeconds &&
        _difficulty == item.difficulty &&
        _note.text.trim() == (item.note ?? '');
  }

  String? _between(String? value, int min, int max, String what) {
    final number = int.tryParse((value ?? '').trim());
    return number == null || number < min || number > max
        ? 'Enter $what from $min to $max.'
        : null;
  }

  Future<void> _save() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) return;
    if (_unchanged) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await ref
          .read(physioRepositoryProvider)
          .editPrescription(
            patientId: widget.patient.id,
            planId: widget.plan.id,
            itemId: widget.item.id,
            sets: int.parse(_sets.text.trim()),
            reps: int.parse(_reps.text.trim()),
            restSeconds: _rest,
            difficulty: _difficulty,
            note: _note.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final digits = [FilteringTextInputFormatter.digitsOnly];
    // A rest set before the current choices existed is still offered.
    final rests = {...restOptions, widget.item.restSeconds}.toList()..sort();
    return AlertDialog(
      title: Text('Edit ${widget.item.exercise.name}'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                InlineBanner(key: const Key('rx-error'), message: _error!),
                const SizedBox(height: 16),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: LabeledField(
                      label: 'Sets',
                      child: TextFormField(
                        key: const Key('rx-sets'),
                        controller: _sets,
                        keyboardType: TextInputType.number,
                        inputFormatters: digits,
                        validator: (v) => _between(v, 1, 10, 'sets'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: LabeledField(
                      label: 'Reps',
                      child: TextFormField(
                        key: const Key('rx-reps'),
                        controller: _reps,
                        keyboardType: TextInputType.number,
                        inputFormatters: digits,
                        validator: (v) => _between(v, 1, 50, 'reps'),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: LabeledField(
                      label: 'Rest between sets',
                      child: DropdownButtonFormField<int>(
                        key: const Key('rx-rest'),
                        initialValue: _rest,
                        isExpanded: true,
                        items: [
                          for (final seconds in rests)
                            DropdownMenuItem(
                              value: seconds,
                              child: Text(seconds == 0 ? 'None' : '$seconds s'),
                            ),
                        ],
                        onChanged: (value) =>
                            setState(() => _rest = value ?? _rest),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: LabeledField(
                      label: 'Difficulty',
                      child: DropdownButtonFormField<Difficulty>(
                        key: const Key('rx-difficulty'),
                        initialValue: _difficulty,
                        isExpanded: true,
                        items: [
                          for (final level in Difficulty.values)
                            DropdownMenuItem(
                              value: level,
                              child: Text(level.label),
                            ),
                        ],
                        onChanged: (value) =>
                            setState(() => _difficulty = value ?? _difficulty),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              LabeledField(
                label: 'Note for the patient',
                child: TextFormField(
                  key: const Key('rx-note'),
                  controller: _note,
                  maxLength: 200,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: 'Optional',
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Applies to sessions ${widget.patient.fullName} starts from now on. '
                'Sessions already completed keep the prescription they were done '
                'with, and the values you replace stay in the change history.',
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        BusyButton(
          key: const Key('rx-save'),
          label: 'Save Changes',
          busy: _busy,
          onPressed: _save,
        ),
      ],
    );
  }
}

/// Every edit made to a plan's prescriptions, in the order they were made.
class PrescriptionHistoryDialog extends ConsumerWidget {
  const PrescriptionHistoryDialog({
    super.key,
    required this.patient,
    required this.plan,
  });

  final PatientSummary patient;
  final ExercisePlan plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (patientId: patient.id, planId: plan.id);
    final edits = ref.watch(planEditsProvider(key));
    return AlertDialog(
      title: Text('Change history: ${plan.name}'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Entry(
              when: plan.createdAt,
              title: 'Plan assigned by ${plan.assignedBy.fullName}',
              lines: const [],
            ),
            AsyncSection(
              value: edits,
              onRetry: () => ref.invalidate(planEditsProvider(key)),
              builder: (edits) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (edits.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'Nothing has been edited since.',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  for (final edit in edits)
                    _Entry(
                      key: Key('history-entry-${edit.id}'),
                      when: edit.editedAt,
                      title:
                          '${edit.exerciseName} edited by ${edit.editedBy.fullName}',
                      lines: [
                        for (final change in edit.changes) change.description,
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const Key('history-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry({
    super.key,
    required this.when,
    required this.title,
    required this.lines,
  });

  final DateTime when;
  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 5),
            child: Icon(
              Icons.fiber_manual_record,
              size: 10,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatDateTime(when),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.text,
                  ),
                ),
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      line,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
