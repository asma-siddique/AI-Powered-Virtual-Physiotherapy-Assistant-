import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/files/file_saver.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import 'physio_repository.dart';

/// How far back a report looks.
enum ReportRange {
  month('Last 30 days', 30),
  quarter('Last 3 months', 91),
  year('Last 12 months', 365);

  const ReportRange(this.label, this.days);

  final String label;
  final int days;
}

/// Exports one patient's progress report as a PDF (US 5.3). The server only
/// produces it for a patient assigned to the physiotherapist asking.
class ReportDialog extends ConsumerStatefulWidget {
  const ReportDialog({super.key, required this.patient});

  final PatientSummary patient;

  @override
  ConsumerState<ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends ConsumerState<ReportDialog> {
  ReportRange _range = ReportRange.quarter;
  bool _busy = false;
  bool _done = false;
  String? _error;

  Future<void> _download() async {
    setState(() {
      _busy = true;
      _done = false;
      _error = null;
    });
    final until = DateTime.now();
    try {
      final file = await ref
          .read(physioRepositoryProvider)
          .patientReport(
            widget.patient.id,
            since: until.subtract(Duration(days: _range.days)),
            until: until,
          );
      await ref.read(fileSaverProvider)(
        file.bytes,
        file.filename,
        'application/pdf',
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = true;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    } on FileSavingUnsupported {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Reports can be downloaded from the web app for now.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      key: const Key('report-dialog'),
      title: const Text('Export progress report'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A PDF of ${widget.patient.fullName}\'s sessions, form scores, '
              'trend, pain ratings and notes.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final range in ReportRange.values)
                  ChoiceChip(
                    key: Key('report-range-${range.name}'),
                    label: Text(range.label),
                    selected: range == _range,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() {
                            _range = range;
                            _done = false;
                          }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'The report holds health information. Keep the file somewhere '
              'only you and your patient can reach.',
              style: text.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              InlineBanner(key: const Key('report-error'), message: _error!),
            ],
            if (_done) ...[
              const SizedBox(height: 12),
              const InlineBanner(
                key: Key('report-done'),
                tone: BannerTone.success,
                message: 'The report has been downloaded.',
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        BusyButton(
          key: const Key('report-download'),
          label: 'Download PDF',
          icon: Icons.download_rounded,
          busy: _busy,
          onPressed: _download,
        ),
      ],
    );
  }
}
