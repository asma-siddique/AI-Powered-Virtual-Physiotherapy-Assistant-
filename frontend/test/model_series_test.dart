// US 4.1: when a trained model scores the session, each repetition is sent
// with what was measured in every one of its frames.
import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/features/session/live_session.dart';
import 'package:physioai/features/session/precheck.dart';
import 'package:physioai/features/session/repetitions.dart';

import 'live_session_test.dart' hide main;

/// What the server asks for, in the order the model was trained with.
const spec = SeriesSpec(
  joints: ['shoulder', 'elbow', 'hip', 'knee', 'ankle'],
  checks: ['trunk_lean', 'elbow_bend', 'depth'],
  channels: [
    'left_shoulder',
    'right_shoulder',
    'left_elbow',
    'right_elbow',
    'left_hip',
    'right_hip',
    'left_knee',
    'right_knee',
    'left_ankle',
    'right_ankle',
    'trunk_lean',
    'elbow_bend',
    'depth',
  ],
  maxFrames: 900,
);

LiveSessionEngine engineWith(SeriesSpec? series) => LiveSessionEngine(
  exerciseSlug: 'arm-abduction',
  targetJoints: const ['shoulder', 'elbow', 'hip'],
  checkKeys: const ['trunk_lean', 'elbow_bend'],
  sets: 2,
  repsPerSet: 3,
  minVisibility: 0.6,
  aspectRatio: 4 / 3,
  series: series,
);

void main() {
  test('a session scored by the rule sends no frames', () {
    final [rep] = feed(engineWith(null), repFrames(0));

    expect(rep.frames, isNull);
    expect(rep.toJson().containsKey('frames'), isFalse);
  });

  test('every frame of the movement is sent, one value per channel', () {
    final [rep] = feed(engineWith(spec), repFrames(0, lean: 4, elbow: 6));

    final frames = rep.frames!;
    expect(frames.length, inInclusiveRange(4, 10));
    for (final frame in frames) {
      expect(frame, hasLength(spec.channels.length));
    }
    final shoulder = [for (final frame in frames) frame[0]!];
    expect(shoulder.reduce((a, b) => a > b ? a : b), closeTo(90, 0.5));
    final top = frames.firstWhere((frame) => frame[0]! > 89);
    expect(top[1], closeTo(90, 0.5)); // right shoulder
    expect(top[2], closeTo(174, 0.5)); // left elbow, bent by 6
    expect(top[10], closeTo(4, 0.5)); // trunk lean
    expect(top[11], closeTo(6, 0.5)); // elbow bend
  });

  test('what cannot be measured is null, never a guess', () {
    final [rep] = feed(engineWith(spec), repFrames(0, hidden: {'left_wrist'}));

    for (final frame in rep.frames!) {
      // The left elbow's angle needs the hidden wrist; the right one does
      // not. Arm Abduction has no depth to measure.
      expect(frame[2], isNull);
      expect(frame[3], isNotNull);
      expect(frame.last, isNull);
    }
  });

  test('each repetition carries only its own frames', () {
    final engine = engineWith(spec);

    final reps = feed(engine, [...repFrames(0), ...repFrames(1000)]);

    expect(reps, hasLength(2));
    expect(reps[1].frames!.length, reps[0].frames!.length);
  });

  test('a very long repetition is thinned evenly to what the server reads', () {
    const few = SeriesSpec(
      joints: ['shoulder'],
      checks: [],
      channels: ['left_shoulder', 'right_shoulder'],
      maxFrames: 4,
    );

    final [rep] = feed(engineWith(few), repFrames(0));

    final frames = rep.frames!;
    expect(frames, hasLength(4));
    // The first and the last frame of the movement are both kept.
    final [all] = feed(
      engineWith(
        const SeriesSpec(
          joints: ['shoulder'],
          checks: [],
          channels: ['left_shoulder', 'right_shoulder'],
          maxFrames: 900,
        ),
      ),
      repFrames(0),
    );
    expect(frames.first, all.frames!.first);
    expect(frames.last, all.frames!.last);
  });

  test('frames are sent as rounded numbers and nulls', () {
    final draft = RepetitionDraft(
      setNumber: 1,
      repNumber: 1,
      startedMs: 0,
      endedMs: 900,
      measures: const {'trunk_lean': 1},
      frames: const [
        [89.98765, null],
        [12.3449, 4],
      ],
    );

    expect(draft.toJson()['frames'], [
      [89.99, null],
      [12.34, 4.0],
    ]);
  });

  test('the session says what its model needs and what it made of a rep', () {
    final session = ExerciseSession.fromJson({
      'id': 's-1',
      'status': 'active',
      'started_at': '2026-10-11T09:00:00Z',
      'series': {
        'joints': ['shoulder'],
        'checks': ['trunk_lean'],
        'channels': ['left_shoulder', 'right_shoulder', 'trunk_lean'],
        'max_frames': 900,
      },
    });
    final stored = RecordedRepetition.fromJson({
      'id': 'r-1',
      'set_number': 1,
      'rep_number': 1,
      'started_ms': 0,
      'ended_ms': 900,
      'judged_correct': false,
    });

    expect(session.series!.channels, hasLength(3));
    expect(session.series!.maxFrames, 900);
    expect(stored.judgedCorrect, isFalse);
    // Under the rule the server sends neither.
    expect(
      ExerciseSession.fromJson({
        'id': 's-2',
        'status': 'active',
        'started_at': '2026-10-11T09:00:00Z',
      }).series,
      isNull,
    );
  });
}
