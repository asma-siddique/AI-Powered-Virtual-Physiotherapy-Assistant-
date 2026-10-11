"""Small stand-ins for REHAB24-6 files, in the same formats."""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np

HEADER = (
    "video_id;repetition_number;exercise_id;person_id;first_frame;last_frame;cam17_orientation;"
    "mocap_erroneous;exercise_subtype;lights_on;extra_person_in_cam17;extra_person_in_cam18;correctness"
)
# REHAB24-6 numbering: 1 arm abduction, 2 arm VW (not used), 3 push-ups,
# 4 leg abduction, 5 leg lunge, 6 squats.
EXERCISE_IDS = (1, 2, 3, 4, 5, 6)


def write_segmentation(
    path: Path, people: int = 10, reps_per_video: int = 4, frames_per_rep: int = 40
) -> Path:
    """One video per person and exercise. Each video has `reps_per_video`
    repetitions; every person has correct and incorrect ones of everything."""
    lines = [HEADER]
    video = 0
    for person in range(1, people + 1):
        for exercise in EXERCISE_IDS:
            frame = 10
            for rep in range(1, reps_per_video + 1):
                correct = 0 if rep == reps_per_video else 1
                lines.append(
                    f"PM_{video:03d};{rep};{exercise};{person};{frame};{frame + frames_per_rep - 1};front;0;"
                    f"right arm;1;0;0;{correct}"
                )
                frame += frames_per_rep
            video += 1
    path.write_text("\n".join(lines) + "\n")
    return path


LANDMARK_NAMES = [
    "nose", "left_eye_inner", "left_eye", "left_eye_outer", "right_eye_inner", "right_eye", "right_eye_outer",
    "left_ear", "right_ear", "mouth_left", "mouth_right", "left_shoulder", "right_shoulder", "left_elbow",
    "right_elbow", "left_wrist", "right_wrist", "left_pinky", "right_pinky", "left_index", "right_index",
    "left_thumb", "right_thumb", "left_hip", "right_hip", "left_knee", "right_knee", "left_ankle",
    "right_ankle", "left_heel", "right_heel", "left_foot_index", "right_foot_index",
]  # fmt: skip


def standing_pose(aspect: float, knee: float = 180.0) -> np.ndarray:
    """A side view with both knees at `knee` degrees, as MediaPipe fractions
    (33 x 3: x, y, visibility)."""
    ankle = (0.5 * aspect, 0.9)
    shin = math.radians((180 - knee) / 2)
    knee_at = (ankle[0] + 0.2 * math.sin(shin), ankle[1] - 0.2 * math.cos(shin))
    thigh = shin - math.radians(180 - knee)
    hip = (knee_at[0] + 0.2 * math.sin(thigh), knee_at[1] - 0.2 * math.cos(thigh))
    points = {
        "ankle": ankle,
        "knee": knee_at,
        "hip": hip,
        "shoulder": (hip[0], hip[1] - 0.3),
        "elbow": (hip[0], hip[1] - 0.15),
        "wrist": (hip[0], hip[1]),
        "foot_index": (ankle[0] + 0.1, ankle[1]),
    }
    pose = np.zeros((33, 3), dtype=np.float32)
    for i, name in enumerate(LANDMARK_NAMES):
        part = name.split("_", 1)[1] if name.startswith(("left_", "right_")) else name
        if part in points:
            x, y = points[part]
            pose[i] = (x / aspect, y, 0.95)
        else:
            pose[i] = (0.5, 0.5, 0.1)
    return pose


def write_landmarks(path: Path, frames: int, aspect: float = 4 / 3, knee: float = 180.0, missing=()) -> Path:
    poses = np.stack([standing_pose(aspect, knee) for _ in range(frames)])
    for frame in missing:
        poses[frame] = np.nan
    np.savez_compressed(path, landmarks=poses, aspect=aspect, fps=30.0)
    return path
