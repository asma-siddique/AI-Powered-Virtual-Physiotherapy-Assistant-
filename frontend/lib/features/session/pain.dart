import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../patient/patient_repository.dart';

/// The 0 to 10 pain scale (US 5.3). It is always optional: nothing is chosen
/// to begin with, and tapping the chosen number again takes the answer back.
class PainScale extends StatelessWidget {
  const PainScale({
    super.key,
    required this.name,
    required this.value,
    required this.onChanged,
  });

  /// Prefix of each number's key: "pain-before" gives "pain-before-3".
  final String name;
  final int? value;
  final ValueChanged<int?> onChanged;

  static Color colorFor(int score) => score <= 3
      ? AppColors.severityGreen
      : score <= 6
      ? AppColors.severityAmber
      : AppColors.severityRed;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var score = 0; score <= 10; score++)
              Semantics(
                button: true,
                selected: value == score,
                label: 'Pain $score out of 10',
                excludeSemantics: true,
                child: InkWell(
                  key: Key('$name-$score'),
                  customBorder: const CircleBorder(),
                  onTap: () => onChanged(value == score ? null : score),
                  child: Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: value == score
                          ? colorFor(score)
                          : AppColors.surfaceAlt,
                      border: Border.all(
                        color: value == score
                            ? colorFor(score)
                            : AppColors.border,
                      ),
                    ),
                    child: Text(
                      '$score',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: value == score ? Colors.white : AppColors.text,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '0 is no pain, 10 is the worst you can imagine.',
          style: text.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

/// Asked once a session has ended: how it feels now, and anything the
/// patient wants their physiotherapist to know. Both can be left alone.
class PainAfterCard extends ConsumerStatefulWidget {
  const PainAfterCard({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<PainAfterCard> createState() => _PainAfterCardState();
}

class _PainAfterCardState extends ConsumerState<PainAfterCard> {
  final _note = TextEditingController();
  int? _score;
  bool _busy = false;
  bool _saved = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(patientRepositoryProvider)
          .logPain(
            sessionId: widget.sessionId,
            moment: 'after',
            score: _score,
            note: _note.text.trim(),
          );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _saved = true;
      });
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
    final text = Theme.of(context).textTheme;
    final answered = _score != null || _note.text.trim().isNotEmpty;
    return AppCard(
      key: const Key('pain-after'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('How does it feel now?', style: text.titleMedium),
          const SizedBox(height: 2),
          Text(
            'Optional. Your physiotherapist sees this with your session.',
            style: text.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: 12),
          PainScale(
            name: 'pain-after',
            value: _score,
            onChanged: (value) => setState(() {
              _score = value;
              _saved = false;
            }),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('pain-note'),
            controller: _note,
            maxLength: 500,
            minLines: 1,
            maxLines: 3,
            onChanged: (_) => setState(() => _saved = false),
            decoration: const InputDecoration(
              hintText: 'Anything to tell your physiotherapist?',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            InlineBanner(key: const Key('pain-error'), message: _error!),
          ],
          const SizedBox(height: 8),
          if (_saved)
            const InlineBanner(
              key: Key('pain-saved'),
              tone: BannerTone.success,
              message: 'Saved. Thank you.',
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: BusyButton(
                key: const Key('pain-save'),
                label: 'Save',
                busy: _busy,
                // Nothing chosen and nothing written is simply skipping.
                onPressed: answered ? _save : null,
              ),
            ),
        ],
      ),
    );
  }
}
