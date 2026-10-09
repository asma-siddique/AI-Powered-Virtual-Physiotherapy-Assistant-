import 'dart:typed_data';

/// The 33 body landmarks in MediaPipe Pose Landmarker's own order. The API
/// uses the same names for the landmarks an exercise needs.
const poseLandmarkNames = [
  'nose',
  'left_eye_inner',
  'left_eye',
  'left_eye_outer',
  'right_eye_inner',
  'right_eye',
  'right_eye_outer',
  'left_ear',
  'right_ear',
  'mouth_left',
  'mouth_right',
  'left_shoulder',
  'right_shoulder',
  'left_elbow',
  'right_elbow',
  'left_wrist',
  'right_wrist',
  'left_pinky',
  'right_pinky',
  'left_index',
  'right_index',
  'left_thumb',
  'right_thumb',
  'left_hip',
  'right_hip',
  'left_knee',
  'right_knee',
  'left_ankle',
  'right_ankle',
  'left_heel',
  'right_heel',
  'left_foot_index',
  'right_foot_index',
];

/// Pairs of landmarks joined by a line when the body is drawn over the picture.
const poseBones = [
  ('left_shoulder', 'right_shoulder'),
  ('left_shoulder', 'left_elbow'),
  ('left_elbow', 'left_wrist'),
  ('right_shoulder', 'right_elbow'),
  ('right_elbow', 'right_wrist'),
  ('left_shoulder', 'left_hip'),
  ('right_shoulder', 'right_hip'),
  ('left_hip', 'right_hip'),
  ('left_hip', 'left_knee'),
  ('left_knee', 'left_ankle'),
  ('right_hip', 'right_knee'),
  ('right_knee', 'right_ankle'),
];

class Landmark {
  const Landmark(this.x, this.y, this.visibility);

  /// Position in the camera picture, 0 to 1 from its left and top edges.
  final double x;
  final double y;

  /// How sure the pose model is that this point is in view, 0 to 1.
  final double visibility;
}

/// What the camera saw at one moment.
class PoseFrame {
  const PoseFrame({
    required this.timeMs,
    required this.brightness,
    this.landmarks = const {},
  });

  /// From the camera bridge's packed numbers: brightness, time, then x, y and
  /// visibility for each of the 33 landmarks (or nothing when nobody is seen).
  factory PoseFrame.fromPacked(Float32List data) {
    final landmarks = <String, Landmark>{};
    if (data.length >= 2 + poseLandmarkNames.length * 3) {
      for (var i = 0; i < poseLandmarkNames.length; i++) {
        final at = 2 + i * 3;
        landmarks[poseLandmarkNames[i]] = Landmark(
          data[at],
          data[at + 1],
          data[at + 2],
        );
      }
    }
    return PoseFrame(
      brightness: data[0].toDouble(),
      timeMs: data[1].toDouble(),
      landmarks: landmarks,
    );
  }

  /// Milliseconds on the camera's own clock.
  final double timeMs;

  /// Average brightness of the picture, 0 (black) to 1 (white).
  final double brightness;

  /// Empty when no person was found in the picture.
  final Map<String, Landmark> landmarks;

  double visibilityOf(String name) => landmarks[name]?.visibility ?? 0;
}
