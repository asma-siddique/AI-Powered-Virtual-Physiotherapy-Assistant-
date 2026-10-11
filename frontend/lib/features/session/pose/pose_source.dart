import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pose_models.dart';
import 'pose_source_stub.dart'
    if (dart.library.js_interop) 'pose_source_web.dart';

enum CameraProblem { unsupported, permissionDenied, noCamera, failed }

/// Why the camera could not be used, with words for the patient.
class CameraException implements Exception {
  const CameraException(this.problem);

  final CameraProblem problem;

  String get title => switch (problem) {
    CameraProblem.unsupported => 'Sessions need the web app for now',
    CameraProblem.permissionDenied => 'The camera is blocked',
    CameraProblem.noCamera => 'No camera was found',
    CameraProblem.failed => 'The camera could not be started',
  };

  String get help => switch (problem) {
    CameraProblem.unsupported =>
      'Open PhysioAI in a browser such as Chrome or Edge on a device with a camera.',
    CameraProblem.permissionDenied =>
      'PhysioAI needs your camera to follow your movement. Allow camera access '
          'for this site in your browser (the camera icon in the address bar), then try again. '
          'The video stays on your device and is never uploaded.',
    CameraProblem.noCamera =>
      'Connect a camera, or open PhysioAI on a laptop or phone that has one, then try again.',
    CameraProblem.failed =>
      'Close other apps that may be using the camera, check your connection, then try again.',
  };
}

/// The live camera with the body landmarks found in each picture. The video
/// itself never leaves the device: only landmarks are ever sent anywhere.
abstract class PoseSource {
  /// Asks for the camera and starts tracking. Throws [CameraException].
  Future<void> start();

  Stream<PoseFrame> get frames;

  /// Width divided by height of the camera picture.
  double get aspectRatio;

  /// The camera picture, mirrored so it behaves like a mirror.
  Widget preview();

  Future<void> stop();
}

/// The camera for the session on screen; switched off when that screen closes.
final poseSourceProvider = Provider.autoDispose<PoseSource>((ref) {
  final source = createPoseSource();
  ref.onDispose(source.stop);
  return source;
});
