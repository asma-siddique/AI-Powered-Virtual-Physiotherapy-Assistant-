import 'dart:async';

import 'package:physioai/core/animations.dart';

/// Runs before every test file. Decorative motion (turning holograms,
/// pulses, count-ups) is switched off so every screen settles at once and
/// `pumpAndSettle` never waits on an animation that loops for ever.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  Motion.enabled = false;
  await testMain();
}
