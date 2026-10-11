"""One training example per annotated repetition and camera.

Every frame of a repetition is measured with the app's own feature code
(app.pose_features): the joint angles of both sides and every check the app
knows, for that exercise. The frames are then resampled to a fixed length, so
a slow and a quick repetition look alike to the model. Values that could not
be measured (a landmark not clearly in view, a check an exercise does not
have) are never guessed: they are filled for the model's sake but marked in a
mask that is fed to it alongside.

    python -m rehab.dataset --segmentation data/Segmentation.csv \
        --splits splits/rehab24_splits.json --landmarks data/landmarks --out data/reps.npz

Repetitions whose frames mostly have no pose are left out, and how many is
written in the dataset's manifest, never silently.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter
from collections.abc import Sequence
from pathlib import Path

import numpy as np

from rehab._backend import LANDMARKS, MIN_VISIBILITY, frame_features
from rehab.segmentation import SLUGS, Repetition, file_sha256, read_segmentation
from rehab.splits import load as load_splits
from rehab.splits import split_of

JOINTS = ("shoulder", "elbow", "hip", "knee", "ankle")
JOINT_CHANNELS = tuple(f"{side}_{joint}" for joint in JOINTS for side in ("left", "right"))
CHECK_CHANNELS = ("trunk_lean", "elbow_bend", "knee_bend", "knee_valgus", "knee_forward", "hip_sag", "depth")
CHANNELS = JOINT_CHANNELS + CHECK_CHANNELS
STEPS = 32  # frames per repetition after resampling
MIN_POSE_SHARE = 0.5  # a repetition needs a pose in at least this share of its frames
ANGLE_SCALE = 180.0


def frame_vector(pose: np.ndarray, *, aspect: float, slug: str) -> np.ndarray:
    """Every channel for one frame, in degrees; NaN where it cannot be measured."""
    out = np.full(len(CHANNELS), np.nan, dtype=np.float32)
    if not np.isfinite(pose[0, 0]):
        return out
    landmarks = {
        name: (float(x), float(y), float(v)) for name, (x, y, v) in zip(LANDMARKS, pose, strict=True)
    }
    features = frame_features(
        landmarks,
        aspect_ratio=aspect,
        exercise_slug=slug,
        target_joints=JOINTS,
        check_keys=CHECK_CHANNELS,
        min_visibility=MIN_VISIBILITY,
    )
    for i, name in enumerate(JOINT_CHANNELS):
        value = features.joint_angles.get(name)
        if value is not None:
            out[i] = value
    for j, name in enumerate(CHECK_CHANNELS, start=len(JOINT_CHANNELS)):
        value = features.checks.get(name)
        if value is not None:
            out[j] = value
    return out


def resample(series: np.ndarray, steps: int = STEPS) -> tuple[np.ndarray, np.ndarray]:
    """(frames x channels) -> values and mask, both (channels x steps).

    Each channel is linearly interpolated over the frames where it was
    measured. The mask says, for each step, whether the nearest original frame
    had a measurement; a channel never measured is all zeros with mask 0."""
    frames, channels = series.shape
    positions = np.linspace(0, frames - 1, steps)
    nearest = np.rint(positions).astype(int)
    values = np.zeros((channels, steps), dtype=np.float32)
    mask = np.zeros((channels, steps), dtype=np.float32)
    index = np.arange(frames)
    for c in range(channels):
        valid = np.isfinite(series[:, c])
        if not valid.any():
            continue
        values[c] = np.interp(positions, index[valid], series[valid, c])
        mask[c] = valid[nearest]
    return values / ANGLE_SCALE, mask


def repetition_example(
    rep: Repetition, landmarks: np.ndarray, aspect: float, steps: int = STEPS
) -> tuple[np.ndarray, np.ndarray, float] | None:
    """Values, mask and the share of frames with a pose; None when the
    repetition lies outside the video."""
    if rep.first_frame >= len(landmarks):
        return None
    frames = landmarks[rep.first_frame : min(rep.last_frame, len(landmarks) - 1) + 1]
    series = np.stack([frame_vector(pose, aspect=aspect, slug=rep.exercise) for pose in frames])
    pose_share = float(np.isfinite(frames[:, 0, 0]).mean())
    values, mask = resample(series, steps)
    return values, mask, pose_share


def sha256_of_files(paths: Sequence[Path]) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.name.encode())
        digest.update(Path(path).read_bytes())
    return digest.hexdigest()


def build(segmentation: Path, splits: Path, landmarks_dir: Path, steps: int = STEPS) -> tuple[dict, dict]:
    repetitions = read_segmentation(segmentation)
    record = load_splits(splits)
    if record["segmentation_sha256"] != file_sha256(segmentation):
        raise SystemExit("the splits were made from a different Segmentation.csv; make them again")
    which = split_of(record)
    files = sorted(Path(landmarks_dir).glob("*_c*.npz"))
    by_video: dict[str, list[Path]] = {}
    for path in files:
        by_video.setdefault(path.stem.rsplit("_c", 1)[0], []).append(path)

    rows: dict[str, list] = {
        k: [] for k in ("x", "mask", "exercise", "label", "person", "split", "key", "camera")
    }
    skipped: Counter = Counter()
    for path in files:
        video_id, camera = path.stem.rsplit("_c", 1)
        data = np.load(path)
        landmarks, aspect = data["landmarks"], float(data["aspect"])
        for rep in (r for r in repetitions if r.video_id == video_id):
            example = repetition_example(rep, landmarks, aspect, steps)
            if example is None:
                skipped["outside the video"] += 1
                continue
            values, mask, pose_share = example
            if pose_share < MIN_POSE_SHARE:
                skipped["no pose in most frames"] += 1
                continue
            rows["x"].append(values)
            rows["mask"].append(mask)
            rows["exercise"].append(SLUGS.index(rep.exercise))
            rows["label"].append(1 if rep.correct else 0)
            rows["person"].append(rep.person)
            rows["split"].append(which[rep.person])
            rows["key"].append(rep.key)
            rows["camera"].append(int(camera))
    missing_videos = sorted({r.video_id for r in repetitions} - set(by_video))
    arrays = {
        "x": np.asarray(rows["x"], dtype=np.float32).reshape(-1, len(CHANNELS), steps),
        "mask": np.asarray(rows["mask"], dtype=np.float32).reshape(-1, len(CHANNELS), steps),
        "exercise": np.asarray(rows["exercise"], dtype=np.int64),
        "label": np.asarray(rows["label"], dtype=np.int64),
        "person": np.asarray(rows["person"], dtype=np.int64),
        "split": np.asarray(rows["split"]),
        "key": np.asarray(rows["key"]),
        "camera": np.asarray(rows["camera"], dtype=np.int64),
    }
    manifest = {
        "dataset": "REHAB24-6",
        "segmentation_sha256": record["segmentation_sha256"],
        "splits_sha256": file_sha256(splits),
        "landmarks_sha256": sha256_of_files(files),
        "channels": list(CHANNELS),
        "exercises": list(SLUGS),
        "steps": steps,
        "examples": {name: int((arrays["split"] == name).sum()) for name in ("train", "val", "test")},
        "skipped": dict(skipped),
        "videos_without_landmarks": missing_videos,
    }
    return arrays, manifest


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--segmentation", type=Path, required=True)
    parser.add_argument("--splits", type=Path, required=True)
    parser.add_argument("--landmarks", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    arrays, manifest = build(args.segmentation, args.splits, args.landmarks)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(args.out, **arrays)
    manifest["dataset_sha256"] = file_sha256(args.out)
    args.out.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({k: manifest[k] for k in ("examples", "skipped", "videos_without_landmarks")}, indent=2))


if __name__ == "__main__":
    main()
