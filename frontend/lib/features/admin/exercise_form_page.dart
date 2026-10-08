import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../shell/page_widgets.dart';
import 'exercise_library_repository.dart';

const _bodyAreas = {
  'shoulder': 'Shoulder',
  'upper_body': 'Upper body',
  'back': 'Back',
  'hip': 'Hip',
  'knee': 'Knee',
  'ankle': 'Ankle',
  'whole_body': 'Whole body',
};

String _number(double value) =>
    value == value.roundToDouble() ? value.toInt().toString() : '$value';

/// The editable fields of one severity check.
class _CheckDraft {
  _CheckDraft([SeverityCheck? check])
    : key = check?.key,
      label = TextEditingController(text: check?.label ?? ''),
      measure = TextEditingController(text: check?.measure ?? ''),
      unit = TextEditingController(text: check?.unit ?? 'degrees'),
      info = TextEditingController(
        text: check == null ? '' : _number(check.info),
      ),
      amber = TextEditingController(
        text: check == null ? '' : _number(check.amber),
      ),
      red = TextEditingController(
        text: check?.red == null ? '' : _number(check!.red!),
      ),
      message = TextEditingController(text: check?.correctiveMessage ?? '');

  /// Kept for existing checks, so recorded results keep referring to the same
  /// check after a rename. New checks get one from their label.
  final String? key;
  final TextEditingController label;
  final TextEditingController measure;
  final TextEditingController unit;
  final TextEditingController info;
  final TextEditingController amber;
  final TextEditingController red;
  final TextEditingController message;

  void dispose() {
    for (final c in [label, measure, unit, info, amber, red, message]) {
      c.dispose();
    }
  }
}

/// Create a new exercise template, or edit an existing one's profile and
/// RED / AMBER / INFO thresholds.
class ExerciseFormPage extends ConsumerWidget {
  const ExerciseFormPage({super.key, this.exerciseId});

  /// Null when adding a new exercise.
  final String? exerciseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (exerciseId == null) return const _ExerciseForm();
    final library = ref.watch(exerciseLibraryProvider);
    return AsyncSection(
      value: library,
      onRetry: () => ref.invalidate(exerciseLibraryProvider),
      builder: (exercises) {
        final exercise = exercises.where((e) => e.id == exerciseId).firstOrNull;
        if (exercise == null) {
          return AppCard(
            child: EmptyState(
              icon: Icons.search_off_rounded,
              message: 'This exercise could not be found.',
              action: OutlinedButton(
                onPressed: () => context.go('/admin/exercises'),
                child: const Text('Back to the library'),
              ),
            ),
          );
        }
        return _ExerciseForm(key: ValueKey(exercise.id), exercise: exercise);
      },
    );
  }
}

class _ExerciseForm extends ConsumerStatefulWidget {
  const _ExerciseForm({super.key, this.exercise});

  final ExerciseTemplate? exercise;

  @override
  ConsumerState<_ExerciseForm> createState() => _ExerciseFormState();
}

class _ExerciseFormState extends ConsumerState<_ExerciseForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.exercise?.name);
  late final _domain = TextEditingController(text: widget.exercise?.domain);
  late final _targets = TextEditingController(
    text: widget.exercise?.primaryTargets,
  );
  late final _joints = TextEditingController(
    text: widget.exercise?.targetJoints.join(', '),
  );
  late final _movement = TextEditingController(
    text: widget.exercise?.movementPattern,
  );
  late final _instructions = TextEditingController(
    text: widget.exercise?.instructions,
  );
  late String _bodyArea = widget.exercise?.bodyArea ?? 'whole_body';
  late final List<_CheckDraft> _checks = [
    for (final check in widget.exercise?.checks ?? const <SeverityCheck>[])
      _CheckDraft(check),
    if (widget.exercise == null) _CheckDraft(),
  ];

  bool _busy = false;
  String? _error;

  bool get _isNew => widget.exercise == null;

  @override
  void dispose() {
    for (final c in [
      _name,
      _domain,
      _targets,
      _joints,
      _movement,
      _instructions,
    ]) {
      c.dispose();
    }
    for (final check in _checks) {
      check.dispose();
    }
    super.dispose();
  }

  List<String> get _jointList => [
    for (final joint in _joints.text.split(','))
      if (joint.trim().isNotEmpty) joint.trim().toLowerCase(),
  ];

  /// "Knee alignment" -> "knee_alignment", made unique within this exercise.
  String _keyFor(String label, Set<String> taken) {
    var base = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (base.isEmpty || !RegExp(r'^[a-z]').hasMatch(base)) base = 'check_$base';
    if (base.length > 36) base = base.substring(0, 36);
    var key = base;
    for (var n = 2; taken.contains(key); n++) {
      key = '${base}_$n';
    }
    return key;
  }

  Map<String, dynamic> _payload() {
    final taken = {
      for (final check in _checks)
        if (check.key != null) check.key!,
    };
    return {
      'name': _name.text.trim(),
      'domain': _domain.text.trim(),
      'body_area': _bodyArea,
      'primary_targets': _targets.text.trim(),
      'target_joints': _jointList,
      'movement_pattern': _movement.text.trim(),
      'instructions': _instructions.text.trim(),
      'checks': [
        for (final check in _checks)
          {
            'key':
                check.key ??
                (() {
                  final key = _keyFor(check.label.text, taken);
                  taken.add(key);
                  return key;
                })(),
            'label': check.label.text.trim(),
            'measure': check.measure.text.trim(),
            'unit': check.unit.text.trim(),
            'info': double.parse(check.info.text.trim()),
            'amber': double.parse(check.amber.text.trim()),
            'red': check.red.text.trim().isEmpty
                ? null
                : double.parse(check.red.text.trim()),
            'corrective_message': check.message.text.trim(),
          },
      ],
    };
  }

  Future<void> _save() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) {
      setState(
        () => _error = 'Some fields need attention. They are marked below.',
      );
      return;
    }
    final labels = [for (final c in _checks) c.label.text.trim().toLowerCase()];
    if (labels.toSet().length != labels.length) {
      setState(() => _error = 'Give each check a different name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final repository = ref.read(exerciseLibraryRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = _isNew
          ? await repository.create(_payload())
          : await repository.update(widget.exercise!.id, _payload());
      ref.invalidate(exerciseLibraryProvider);
      if (!mounted) return;
      context.go('/admin/exercises');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _isNew
                ? '${saved.name} was added. It is switched off until you turn it on.'
                : saved.version == widget.exercise!.version
                ? 'Nothing was changed.'
                : '${saved.name} saved as version ${saved.version}. '
                      'It applies to sessions started from now on.',
          ),
        ),
      );
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _busy = false;
        });
      }
    }
  }

  String? _required(String? value, int min, String message) =>
      (value ?? '').trim().length < min ? message : null;

  double? _parse(String text) => double.tryParse(text.trim());

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : () => context.go('/admin/exercises'),
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('Exercise Library'),
            ),
          ),
          PageIntro(
            title: _isNew ? 'Add exercise' : 'Edit ${widget.exercise!.name}',
            subtitle: _isNew
                ? 'New exercises start switched off. Turn one on once the scoring model supports it.'
                : 'Version ${widget.exercise!.version}. Saving creates a new version that applies '
                      'to sessions started afterwards. Past sessions are never rescored.',
          ),
          if (_error != null) ...[
            InlineBanner(key: const Key('exercise-error'), message: _error!),
            const SizedBox(height: 16),
          ],
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Profile', style: text.titleLarge),
                const SizedBox(height: 16),
                ResponsiveRow(
                  breakpoint: 640,
                  gap: 16,
                  children: [
                    LabeledField(
                      label: 'Name',
                      child: TextFormField(
                        key: const Key('ex-name'),
                        controller: _name,
                        validator: (v) =>
                            _required(v, 2, 'Enter the exercise name.'),
                      ),
                    ),
                    LabeledField(
                      label: 'Rehabilitation area',
                      child: TextFormField(
                        key: const Key('ex-domain'),
                        controller: _domain,
                        validator: (v) => _required(
                          v,
                          2,
                          'Enter the rehabilitation area, for example "Knee rehabilitation".',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ResponsiveRow(
                  breakpoint: 640,
                  gap: 16,
                  children: [
                    LabeledField(
                      label: 'Body area',
                      child: DropdownButtonFormField<String>(
                        initialValue: _bodyAreas.containsKey(_bodyArea)
                            ? _bodyArea
                            : null,
                        isExpanded: true,
                        items: [
                          for (final entry in _bodyAreas.entries)
                            DropdownMenuItem(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                        ],
                        validator: (v) =>
                            v == null ? 'Choose a body area.' : null,
                        onChanged: (value) =>
                            setState(() => _bodyArea = value ?? _bodyArea),
                      ),
                    ),
                    LabeledField(
                      label: 'Main muscles worked',
                      child: TextFormField(
                        key: const Key('ex-targets'),
                        controller: _targets,
                        validator: (v) => _required(
                          v,
                          2,
                          'Enter the main muscles, for example "Quadriceps, glutes".',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                LabeledField(
                  label: 'Target joints',
                  helper:
                      'Separate joints with commas, for example: hip, knee, ankle.',
                  child: TextFormField(
                    key: const Key('ex-joints'),
                    controller: _joints,
                    validator: (_) =>
                        _jointList.isEmpty ? 'Name at least one joint.' : null,
                  ),
                ),
                const SizedBox(height: 16),
                LabeledField(
                  label: 'Expected movement pattern',
                  helper:
                      'How the movement should look, for the clinical record.',
                  child: TextFormField(
                    key: const Key('ex-movement'),
                    controller: _movement,
                    minLines: 2,
                    maxLines: 4,
                    validator: (v) => _required(
                      v,
                      10,
                      'Describe the expected movement in a sentence.',
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                LabeledField(
                  label: 'Instructions for the patient',
                  helper: 'Shown to patients in their plan.',
                  child: TextFormField(
                    key: const Key('ex-instructions'),
                    controller: _instructions,
                    minLines: 2,
                    maxLines: 4,
                    validator: (v) => _required(
                      v,
                      10,
                      'Write the instructions the patient will read.',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Severity thresholds', style: text.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'For each check, enter how far the movement may deviate before feedback is '
                  'INFO, then AMBER, then RED. RED pauses the session, so leave it empty for '
                  'checks that are never a safety matter.',
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
                const SizedBox(height: 16),
                for (var i = 0; i < _checks.length; i++) _checkCard(i),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('add-check'),
                    onPressed: _busy || _checks.length >= 8
                        ? null
                        : () => setState(() => _checks.add(_CheckDraft())),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Add check'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _busy ? null : () => context.go('/admin/exercises'),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 12),
              BusyButton(
                key: const Key('save-exercise'),
                label: _isNew ? 'Add Exercise' : 'Save Changes',
                busy: _busy,
                onPressed: _save,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _checkCard(int index) {
    final check = _checks[index];
    String? threshold(String? value, {double? above, bool optional = false}) {
      final raw = (value ?? '').trim();
      if (raw.isEmpty) return optional ? null : 'Enter a number.';
      final number = _parse(raw);
      if (number == null || number < 0) return 'Enter a number.';
      if (above != null && number <= above) {
        return 'Must be above ${_number(above)}.';
      }
      return null;
    }

    Widget level(
      String label,
      String id,
      TextEditingController controller,
      Color color, {
      double? Function()? above,
      bool optional = false,
    }) => LabeledField(
      label: label,
      child: TextFormField(
        key: Key('check-$index-$id'),
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        validator: (v) =>
            threshold(v, above: above?.call(), optional: optional),
        decoration: InputDecoration(
          hintText: optional ? 'Never' : null,
          prefixIcon: Icon(Icons.circle, size: 12, color: color),
        ),
      ),
    );

    Widget pair(Widget first, Widget second) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: first),
        const SizedBox(width: 16),
        Expanded(child: second),
      ],
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Check ${index + 1}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_checks.length > 1)
                IconButton(
                  key: Key('remove-check-$index'),
                  tooltip: 'Remove this check',
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  onPressed: _busy
                      ? null
                      : () {
                          final removed = _checks[index];
                          setState(() => _checks.removeAt(index));
                          // Its fields are still mounted until the rebuild finishes.
                          WidgetsBinding.instance.addPostFrameCallback(
                            (_) => removed.dispose(),
                          );
                        },
                ),
            ],
          ),
          const SizedBox(height: 8),
          ResponsiveRow(
            breakpoint: 640,
            gap: 16,
            flex: const [2, 3],
            children: [
              LabeledField(
                label: 'Name',
                child: TextFormField(
                  key: Key('check-$index-label'),
                  controller: check.label,
                  validator: (v) => _required(
                    v,
                    2,
                    'Name the check, for example "Knee alignment".',
                  ),
                ),
              ),
              LabeledField(
                label: 'What is measured',
                child: TextFormField(
                  key: Key('check-$index-measure'),
                  controller: check.measure,
                  validator: (v) =>
                      _required(v, 2, 'Describe what is measured.'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Four columns when there is room, two rows of two on a phone.
          ResponsiveRow(
            breakpoint: 640,
            gap: 16,
            children: [
              pair(
                LabeledField(
                  label: 'Unit',
                  child: TextFormField(
                    controller: check.unit,
                    validator: (v) => _required(v, 1, 'Enter a unit.'),
                  ),
                ),
                level('INFO from', 'info', check.info, AppColors.primary),
              ),
              pair(
                level(
                  'AMBER from',
                  'amber',
                  check.amber,
                  AppColors.warning,
                  above: () => _parse(check.info.text),
                ),
                level(
                  'RED from',
                  'red',
                  check.red,
                  AppColors.error,
                  above: () => _parse(check.amber.text),
                  optional: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          LabeledField(
            label: 'Corrective message',
            helper: 'What the patient is told when this check is not met.',
            child: TextFormField(
              key: Key('check-$index-message'),
              controller: check.message,
              validator: (v) =>
                  _required(v, 5, 'Write the message the patient will see.'),
            ),
          ),
        ],
      ),
    );
  }
}
