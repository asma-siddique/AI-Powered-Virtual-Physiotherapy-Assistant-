"""Per-frame joint-angle features for user story 3.2 (SCRUM-53).

Turns the 33 MediaPipe landmarks of one camera frame into the angles an
exercise's template asks for. The app computes the same numbers live in
`frontend/lib/features/session/pose/pose_features.dart`; this module is the
Python twin used for model training and for checking the app. Both are held to
the shared cases in `backend/tests/fixtures/pose_feature_cases.json`, so a
change to one without the other fails a test.

Conventions (identical in both versions):

* Landmark x and y are fractions of the picture's width and height, with y
  growing downwards. Before any angle is measured, x is multiplied by the
  picture's aspect ratio (width / height) so both axes are in the same unit;
  otherwise every angle is skewed on a non-square camera.
* A landmark counts only when its visibility is at least `min_visibility`. A
  feature whose landmarks are not all usable is `None`; it is never guessed,
  so nothing is ever scored from landmarks that were not clearly in view.
* All angles are in degrees.

What each value means:

* Joint angles, per side (`left_knee`, `right_elbow`, ...), for the template's
  `target_joints`: the inner angle at the joint, 180 when the limb is straight.
  shoulder = hip-shoulder-elbow, elbow = shoulder-elbow-wrist,
  hip = shoulder-hip-knee, knee = hip-knee-ankle, ankle = knee-ankle-foot_index.
  Wrist has no angle (MediaPipe gives no hand landmarks beyond the wrist that
  the templates use).
* Checks, keyed like the template's `checks`:
  - trunk_lean: angle of the trunk (hips' midpoint to shoulders' midpoint) from
    vertical. Sideways lean in a front view, forward lean in a side view.
  - elbow_bend / knee_bend: how far the elbow / knee is from straight
    (180 minus its angle), the larger of the two sides.
  - knee_valgus: how far the knee has moved off the hip-ankle line towards the
    body's midline (180 minus the knee angle when the knee is on the midline
    side, 0 when it is on the outside), the larger of the two sides.
  - knee_forward: angle of the shin (ankle to knee) from vertical, for the
    more bent knee (the front knee in a lunge).
  - hip_sag: how far the hips are off the shoulder-ankle line
    (180 minus the shoulder-hip-ankle angle), the larger of the two sides.
  - depth: the exercise's working joint angle, the smaller of the two sides;
    elbow for push-ups, knee for squats. Lower means deeper. Turning it into
    "short of the target at the lowest point" needs the whole repetition and
    belongs to the severity engine (SCRUM-66), not to a single frame.

Where both sides are measured and one value is reported, the worse side is
taken, so a problem on either side is never hidden.
"""

from __future__ import annotations

import math
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field

from app.pose import MIN_VISIBILITY

Point = tuple[float, float]
# name -> (x, y, visibility), with x and y as fractions of the picture.
Landmarks = Mapping[str, Sequence[float]]

SIDES = ("left", "right")

# Joint name -> the three landmarks (without side prefix) whose middle one is
# the joint.
JOINT_TRIPLETS: dict[str, tuple[str, str, str]] = {
    "shoulder": ("hip", "shoulder", "elbow"),
    "elbow": ("shoulder", "elbow", "wrist"),
    "hip": ("shoulder", "hip", "knee"),
    "knee": ("hip", "knee", "ankle"),
    "ankle": ("knee", "ankle", "foot_index"),
}

# The working joint whose angle is the "depth" of each exercise.
DEPTH_JOINT = {"push-ups": "elbow", "squats": "knee"}


@dataclass(frozen=True)
class FrameFeatures:
    """Everything measured in one frame. A value of None means the landmarks it
    needs were not clearly in view."""

    joint_angles: dict[str, float | None] = field(default_factory=dict)
    checks: dict[str, float | None] = field(default_factory=dict)
    # Check keys of the template that this version cannot measure.
    unsupported: list[str] = field(default_factory=list)


class _Frame:
    def __init__(self, landmarks: Landmarks, aspect_ratio: float, min_visibility: float):
        if aspect_ratio <= 0:
            raise ValueError("aspect_ratio must be positive")
        self._landmarks = landmarks
        self._aspect = aspect_ratio
        self._min_visibility = min_visibility

    def point(self, name: str) -> Point | None:
        landmark = self._landmarks.get(name)
        if landmark is None or landmark[2] < self._min_visibility:
            return None
        return (landmark[0] * self._aspect, landmark[1])

    def points(self, *names: str) -> list[Point] | None:
        found = [self.point(name) for name in names]
        if any(p is None for p in found):
            return None
        return found  # type: ignore[return-value]


def _angle_at(a: Point, b: Point, c: Point) -> float | None:
    """Inner angle at b between b->a and b->c, 0 to 180."""
    v1 = (a[0] - b[0], a[1] - b[1])
    v2 = (c[0] - b[0], c[1] - b[1])
    n1 = math.hypot(*v1)
    n2 = math.hypot(*v2)
    if n1 == 0 or n2 == 0:
        return None
    cos = (v1[0] * v2[0] + v1[1] * v2[1]) / (n1 * n2)
    return math.degrees(math.acos(max(-1.0, min(1.0, cos))))


def _from_vertical(bottom: Point, top: Point) -> float | None:
    """Angle of the segment bottom->top from straight up, 0 to 180."""
    dx = top[0] - bottom[0]
    dy = top[1] - bottom[1]
    length = math.hypot(dx, dy)
    if length == 0:
        return None
    # Up is -y in picture coordinates.
    cos = -dy / length
    return math.degrees(math.acos(max(-1.0, min(1.0, cos))))


def _cross(origin: Point, a: Point, b: Point) -> float:
    return (a[0] - origin[0]) * (b[1] - origin[1]) - (a[1] - origin[1]) * (b[0] - origin[0])


def _side_angle(frame: _Frame, side: str, joint: str) -> float | None:
    names = [f"{side}_{part}" for part in JOINT_TRIPLETS[joint]]
    pts = frame.points(*names)
    return None if pts is None else _angle_at(*pts)


def _worst(values: list[float | None], pick: Callable[[list[float]], float]) -> float | None:
    usable = [v for v in values if v is not None]
    return pick(usable) if usable else None


def _trunk_lean(frame: _Frame, slug: str) -> float | None:
    both = frame.points("left_shoulder", "right_shoulder", "left_hip", "right_hip")
    if both is not None:
        ls, rs, lh, rh = both
        top = ((ls[0] + rs[0]) / 2, (ls[1] + rs[1]) / 2)
        bottom = ((lh[0] + rh[0]) / 2, (lh[1] + rh[1]) / 2)
        return _from_vertical(bottom, top)
    # Side view: the far side is often hidden, so use whichever side is visible.
    for side in SIDES:
        pts = frame.points(f"{side}_shoulder", f"{side}_hip")
        if pts is not None:
            return _from_vertical(pts[1], pts[0])
    return None


def _bend(joint: str) -> Callable[[_Frame, str], float | None]:
    def measure(frame: _Frame, slug: str) -> float | None:
        angles = [_side_angle(frame, side, joint) for side in SIDES]
        return _worst([None if a is None else 180.0 - a for a in angles], max)

    return measure


def _knee_valgus(frame: _Frame, slug: str) -> float | None:
    values: list[float | None] = []
    for side, other in (("left", "right"), ("right", "left")):
        pts = frame.points(f"{side}_hip", f"{side}_knee", f"{side}_ankle", f"{other}_hip")
        if pts is None:
            values.append(None)
            continue
        hip, knee, ankle, other_hip = pts
        angle = _angle_at(hip, knee, ankle)
        if angle is None:
            values.append(None)
            continue
        # The knee is on the midline side when it lies on the same side of the
        # hip-ankle line as the other hip.
        knee_side = _cross(hip, ankle, knee)
        midline_side = _cross(hip, ankle, other_hip)
        inward = knee_side * midline_side > 0
        values.append(180.0 - angle if inward else 0.0)
    return _worst(values, max)


def _knee_forward(frame: _Frame, slug: str) -> float | None:
    best: tuple[float, float] | None = None  # (knee angle, shin angle)
    for side in SIDES:
        pts = frame.points(f"{side}_hip", f"{side}_knee", f"{side}_ankle")
        if pts is None:
            continue
        hip, knee, ankle = pts
        knee_angle = _angle_at(hip, knee, ankle)
        shin = _from_vertical(ankle, knee)
        if knee_angle is None or shin is None:
            continue
        if best is None or knee_angle < best[0]:
            best = (knee_angle, shin)
    return None if best is None else best[1]


def _hip_sag(frame: _Frame, slug: str) -> float | None:
    values: list[float | None] = []
    for side in SIDES:
        pts = frame.points(f"{side}_shoulder", f"{side}_hip", f"{side}_ankle")
        angle = None if pts is None else _angle_at(*pts)
        values.append(None if angle is None else 180.0 - angle)
    return _worst(values, max)


def _depth(frame: _Frame, slug: str) -> float | None:
    joint = DEPTH_JOINT.get(slug)
    if joint is None:
        return None
    return _worst([_side_angle(frame, side, joint) for side in SIDES], min)


CHECKS: dict[str, Callable[[_Frame, str], float | None]] = {
    "trunk_lean": _trunk_lean,
    "elbow_bend": _bend("elbow"),
    "knee_bend": _bend("knee"),
    "knee_valgus": _knee_valgus,
    "knee_forward": _knee_forward,
    "hip_sag": _hip_sag,
    "depth": _depth,
}


def is_supported(check_key: str, exercise_slug: str) -> bool:
    if check_key == "depth":
        return exercise_slug in DEPTH_JOINT
    return check_key in CHECKS


def frame_features(
    landmarks: Landmarks,
    *,
    aspect_ratio: float,
    exercise_slug: str,
    target_joints: Sequence[str],
    check_keys: Sequence[str],
    min_visibility: float = MIN_VISIBILITY,
) -> FrameFeatures:
    """The joint angles and check measurements of one frame, driven by the
    exercise's template rather than a fixed generic set."""
    frame = _Frame(landmarks, aspect_ratio, min_visibility)
    joint_angles: dict[str, float | None] = {}
    for joint in target_joints:
        if joint not in JOINT_TRIPLETS:
            continue
        for side in SIDES:
            joint_angles[f"{side}_{joint}"] = _side_angle(frame, side, joint)
    checks: dict[str, float | None] = {}
    unsupported: list[str] = []
    for key in check_keys:
        if not is_supported(key, exercise_slug):
            unsupported.append(key)
            continue
        checks[key] = CHECKS[key](frame, exercise_slug)
    return FrameFeatures(joint_angles=joint_angles, checks=checks, unsupported=unsupported)
