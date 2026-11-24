"""The body landmarks the app tracks and what a camera pre-check must establish
before a session may start. This is the single source for both: the app asks
the API what to look for, and the API judges the result against the same rules."""

from collections.abc import Iterable

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

# Which way the patient faces, from the width of the shoulders against the
# height of the trunk (x scaled by the picture's aspect ratio). Measured on
# REHAB24-6's labelled views: from the front 0.59 to 0.80 (5th to 95th
# percentile), at an angle 0.28 to 0.60, from the side 0.02 to 0.22 (push-ups
# up to 0.31).
FRONT_MIN_RATIO = 0.55
SIDE_MAX_RATIO = 0.35
VIEWS = ("front", "side")


def facing_ok(view: str, shoulder_ratio: float | None) -> bool:
    """Whether the patient faces the camera the way the exercise needs."""
    if shoulder_ratio is None:
        return False
    if view == "side":
        return shoulder_ratio <= SIDE_MAX_RATIO
    return shoulder_ratio >= FRONT_MIN_RATIO


def _other_side(name: str) -> str | None:
    if name.startswith("left_"):
        return "right_" + name[5:]
    if name.startswith("right_"):
        return "left_" + name[6:]
    return None


# The joints a check has to see to be measured (see app/pose_features.py). An
# elbow's bend, for example, cannot be measured without the wrist.
CHECK_JOINTS = {
    "trunk_lean": ("shoulder", "hip"),
    "elbow_bend": ("shoulder", "elbow", "wrist"),
    "knee_bend": ("hip", "knee", "ankle"),
    "knee_valgus": ("hip", "knee", "ankle"),
    "knee_forward": ("hip", "knee", "ankle"),
    "hip_sag": ("shoulder", "hip", "ankle"),
}

# Depth is measured on each exercise's working joint (DEPTH_JOINT in
# app/pose_features.py), so what it has to see depends on the exercise: a
# push-up's elbow angle cannot be measured without the wrist.
DEPTH_CHECK_JOINTS = {
    "push-ups": ("shoulder", "elbow", "wrist"),
    "squats": ("hip", "knee", "ankle"),
}


def required_landmarks(
    target_joints: list[str], check_keys: Iterable[str] = (), exercise_slug: str = ""
) -> list[str]:
    """Landmarks that must be visible for an exercise with these target joints
    and these checks, in the pose model's own order. A check that could never
    be measured would silently never give feedback, so what it needs is asked
    for before the session starts."""
    needed = set(_TRUNK)
    joints = list(target_joints)
    for key in check_keys:
        if key == "depth":
            joints += DEPTH_CHECK_JOINTS.get(exercise_slug, ())
        else:
            joints += CHECK_JOINTS.get(key, ())
    for joint in joints:
        # A joint name this version does not know adds nothing rather than
        # blocking the patient: the trunk is always required.
        needed.update(JOINT_LANDMARKS.get(joint, ()))
    return [name for name in LANDMARKS if name in needed]


def precheck_problems(
    required: list[str],
    *,
    brightness: float,
    visibility: dict[str, float],
    held_ms: int,
    view: str = "front",
    shoulder_ratio: float | None = None,
    check_facing: bool = True,
) -> list[str]:
    """Why the submitted camera check does not pass; empty when it does.
    "lighting", "steady", "facing", or "landmark:<name>" for each one not
    clearly in view. From the side the far half of the body is hidden, so a
    joint passes when either side of it is clearly in view."""
    problems = []
    if brightness < MIN_BRIGHTNESS:
        problems.append("lighting")
    for name in required:
        seen = visibility.get(name, 0.0)
        other = _other_side(name)
        if view == "side" and other is not None:
            seen = max(seen, visibility.get(other, 0.0))
        if seen < MIN_VISIBILITY:
            problems.append(f"landmark:{name}")
    if check_facing and not facing_ok(view, shoulder_ratio):
        problems.append("facing")
    if held_ms < HOLD_MS:
        problems.append("steady")
    return problems
