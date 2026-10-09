"""The body landmarks the app tracks and what a camera pre-check must establish
before a session may start. This is the single source for both: the app asks
the API what to look for, and the API judges the result against the same rules."""

# MediaPipe Pose Landmarker (BlazePose) output order: 33 landmarks.
LANDMARKS = (
    "nose",
    "left_eye_inner",
    "left_eye",
    "left_eye_outer",
    "right_eye_inner",
    "right_eye",
    "right_eye_outer",
    "left_ear",
    "right_ear",
    "mouth_left",
    "mouth_right",
    "left_shoulder",
    "right_shoulder",
    "left_elbow",
    "right_elbow",
    "left_wrist",
    "right_wrist",
    "left_pinky",
    "right_pinky",
    "left_index",
    "right_index",
    "left_thumb",
    "right_thumb",
    "left_hip",
    "right_hip",
    "left_knee",
    "right_knee",
    "left_ankle",
    "right_ankle",
    "left_heel",
    "right_heel",
    "left_foot_index",
    "right_foot_index",
)

# The joints an exercise template can name, and the landmarks each one needs.
JOINT_LANDMARKS = {
    "shoulder": ("left_shoulder", "right_shoulder"),
    "elbow": ("left_elbow", "right_elbow"),
    "wrist": ("left_wrist", "right_wrist"),
    "hip": ("left_hip", "right_hip"),
    "knee": ("left_knee", "right_knee"),
    "ankle": ("left_ankle", "right_ankle"),
}
KNOWN_JOINTS = tuple(JOINT_LANDMARKS)

# Always needed: every joint angle is measured against the trunk.
_TRUNK = ("left_shoulder", "right_shoulder", "left_hip", "right_hip")

# How confident the pose model must be that a landmark is in view (0 to 1).
MIN_VISIBILITY = 0.6
# Average brightness of the camera picture (0 black, 1 white). Below this the
# pose model's landmarks become unreliable.
MIN_BRIGHTNESS = 0.25
# The setup has to stay good for this long, so a passing glance does not count.
HOLD_MS = 1500


def required_landmarks(target_joints: list[str]) -> list[str]:
    """Landmarks that must be visible for an exercise with these target joints,
    in the pose model's own order."""
    needed = set(_TRUNK)
    for joint in target_joints:
        # A joint name this version does not know adds nothing rather than
        # blocking the patient: the trunk is always required.
        needed.update(JOINT_LANDMARKS.get(joint, ()))
    return [name for name in LANDMARKS if name in needed]


def precheck_problems(
    required: list[str], *, brightness: float, visibility: dict[str, float], held_ms: int
) -> list[str]:
    """Why the submitted camera check does not pass; empty when it does.
    "lighting", "steady", or "landmark:<name>" for each one not clearly in view."""
    problems = []
    if brightness < MIN_BRIGHTNESS:
        problems.append("lighting")
    problems += [f"landmark:{name}" for name in required if visibility.get(name, 0.0) < MIN_VISIBILITY]
    if held_ms < HOLD_MS:
        problems.append("steady")
    return problems
