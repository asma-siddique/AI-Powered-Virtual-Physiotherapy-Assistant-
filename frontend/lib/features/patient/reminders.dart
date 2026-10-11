import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import 'patient_repository.dart';

const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "Every day", "Mon, Wed and Fri": the days a plan prescribes, Monday 0 to
/// Sunday 6.
String describeDays(List<int> days) {
  final sorted = [...days]..sort();
  if (sorted.length == 7) return 'Every day';
  if (sorted.isEmpty) return 'No days set';
  final names = [for (final day in sorted) _dayNames[day]];
  if (names.length == 1) return names.single;
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

String dayName(int day) => _dayNames[day];

/// When the patient is reminded that their exercises are due (US 6.1).
class ReminderSettings {
  const ReminderSettings({
    required this.enabled,
    required this.time,
    this.utcOffsetMinutes,
    this.days = const [],
  });

  factory ReminderSettings.fromJson(Map<String, dynamic> json) =>
      ReminderSettings(
        enabled: json['enabled'] as bool,
        time: json['time'] as String,
        utcOffsetMinutes: json['utc_offset_minutes'] as int?,
        days: [for (final day in json['days'] as List<dynamic>) day as int],
      );

  final bool enabled;

  /// On the patient's own clock, "18:00".
  final String time;

  /// How far the patient's clock is ahead of UTC as the server knows it;
  /// null until this app has told it.
  final int? utcOffsetMinutes;

  /// The days the plan prescribes; empty without a plan.
  final List<int> days;
}

/// The times a reminder can be set to: every half hour from six in the
/// morning to ten at night.
final reminderTimes = [
  for (var minutes = 6 * 60; minutes <= 22 * 60; minutes += 30)
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
        '${(minutes % 60).toString().padLeft(2, '0')}',
];

/// On My Exercise Plan: the days the plan prescribes, and the reminder the
/// patient gets on those days.
class ReminderCard extends ConsumerStatefulWidget {
  const ReminderCard({super.key, required this.days});

  /// The plan's prescribed days.
  final List<int> days;

  @override
  ConsumerState<ReminderCard> createState() => _ReminderCardState();
}

class _ReminderCardState extends ConsumerState<ReminderCard> {
  bool _busy = false;
  String? _error;
  bool _clockReported = false;

  Future<void> _save({bool? enabled, String? time}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(patientRepositoryProvider)
          .saveReminders(
            enabled: enabled,
            time: time,
            utcOffsetMinutes: ref.read(deviceUtcOffsetProvider),
          );
      ref.invalidate(patientRemindersProvider);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A reminder at "six in the evening" needs to know whose evening. The
  /// app tells the server how far this device's clock is from UTC whenever
  /// the server does not have it, or has an old value (a journey, a clock
  /// change).
  void _reportClock(ReminderSettings settings) {
    final offset = ref.read(deviceUtcOffsetProvider);
    if (_clockReported || settings.utcOffsetMinutes == offset) return;
    _clockReported = true;
    Future.microtask(() async {
      try {
        await ref
            .read(patientRepositoryProvider)
            .saveReminders(utcOffsetMinutes: offset);
        ref.invalidate(patientRemindersProvider);
      } on ApiException catch (_) {
        // Tried again the next time the page opens.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final settings = ref.watch(patientRemindersProvider).valueOrNull;
    if (settings != null) _reportClock(settings);
    final times = {...reminderTimes, ?settings?.time}.toList()..sort();
    return AppCard(
      key: const Key('reminder-card'),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.event_repeat_rounded, color: AppColors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      describeDays(widget.days),
                      key: const Key('plan-days'),
                      style: text.titleMedium,
                    ),
                    Text(
                      'The days your physiotherapist prescribed',
                      style: text.bodySmall?.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (settings != null) ...[
            const Divider(height: 28),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Remind me', style: text.titleSmall),
                      Text(
                        settings.enabled
                            ? 'On those days, at this time'
                            : 'Reminders are off',
                        style: text.bodySmall?.copyWith(
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (settings.enabled) ...[
                  DropdownButton<String>(
                    key: const Key('reminder-time'),
                    value: settings.time,
                    underline: const SizedBox.shrink(),
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value != null) _save(time: value);
                          },
                    items: [
                      for (final time in times)
                        DropdownMenuItem(value: time, child: Text(time)),
                    ],
                  ),
                  const SizedBox(width: 8),
                ],
                Switch(
                  key: const Key('reminder-enabled'),
                  value: settings.enabled,
                  onChanged: _busy ? null : (value) => _save(enabled: value),
                ),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            InlineBanner(key: const Key('reminder-error'), message: _error!),
          ],
        ],
      ),
    );
  }
}
