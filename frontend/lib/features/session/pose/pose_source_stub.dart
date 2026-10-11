import 'package:flutter/widgets.dart';

import 'pose_models.dart';
import 'pose_source.dart';

/// Used where the browser camera bridge does not exist (the Android and iOS
/// builds, and tests). Pose tracking on those platforms is not built yet.
PoseSource createPoseSource() => _UnsupportedPoseSource();

class _UnsupportedPoseSource implements PoseSource {
  @override
  double get aspectRatio => 4 / 3;

  @override
  Stream<PoseFrame> get frames => const Stream.empty();

  @override
  Widget preview() => const SizedBox.shrink();

  @override
  Future<void> start() async =>
      throw const CameraException(CameraProblem.unsupported);

  @override
  Future<void> stop() async {}
}
