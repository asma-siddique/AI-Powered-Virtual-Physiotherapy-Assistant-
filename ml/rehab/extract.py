"""Landmarks from the REHAB24-6 videos, measured the way the app measures them.

The classifier has to learn from the same numbers the app produces live, so
this runs the same model (MediaPipe Pose Landmarker, lite) over the dataset's
RGB videos and keeps x, y and visibility of the 33 landmarks per frame, with
x mirrored exactly as frontend/web/pose_bridge.js does. The motion-capture
skeletons in the dataset use a different body model and are not used here.

Only frames inside annotated repetitions are run through the model (other
frames are stored as "no pose"), which roughly halves the time.

    python -m rehab.extract --videos data/videos --segmentation data/Segmentation.csv \
        --model data/pose_landmarker_lite.task --out data/landmarks --list
    (then the same without --list to run it)

Each video becomes data/landmarks/<video_id>_c<camera>.npz holding
`landmarks` (frames x 33 x 3: x, y, visibility; NaN where no pose was looked
for or found), `aspect` (width / height) and `fps`. Existing files are
skipped, so an interrupted run can simply be started again.
"""

from __future__ import annotations

import argparse
import re
from collections.abc import Sequence
from pathlib import Path

import numpy as np

from rehab.segmentation import Repetition, read_segmentation

VIDEO_SUFFIXES = {".mp4", ".avi", ".mov", ".mkv"}
CAMERAS = (17, 18)
MARGIN_FRAMES = 15  # looked at around each repetition, so tracking has settled
LANDMARKS = 33


def _camera_pattern(camera: int) -> re.Pattern[str]:
    # Accepts names such as PM_000-c17.mp4, PM_000_cam17.avi, PM_000-Camera17.mp4,
    # or a folder named after the camera.
    return re.compile(rf"(?:^|[^0-9])(?:c|cam|camera)?[_ -]?{camera}(?:[^0-9]|$)", re.IGNORECASE)


def find_videos(root: Path, video_ids: Sequence[str]) -> dict[tuple[str, int], Path | str]:
    """(video id, camera) -> its file, or a message saying why none was chosen."""
    files = [p for p in Path(root).rglob("*") if p.suffix.lower() in VIDEO_SUFFIXES]
    found: dict[tuple[str, int], Path | str] = {}
    for video_id in video_ids:
        own = [p for p in files if re.search(rf"(?:^|[^A-Za-z0-9]){re.escape(video_id)}(?:[^A-Za-z0-9]|$)", str(p))]
        for camera in CAMERAS:
            pattern = _camera_pattern(camera)
            matches = [p for p in own if pattern.search(str(p.relative_to(root)).replace(video_id, ""))]
            if len(matches) == 1:
                found[(video_id, camera)] = matches[0]
            elif not matches:
                found[(video_id, camera)] = "no file found"
            else:
                found[(video_id, camera)] = f"{len(matches)} files match: " + ", ".join(p.name for p in matches)
    return found


def frames_to_track(repetitions: Sequence[Repetition], video_id: str) -> set[int]:
    wanted: set[int] = set()
    for r in repetitions:
        if r.video_id == video_id:
            wanted.update(range(max(0, r.first_frame - MARGIN_FRAMES), r.last_frame + MARGIN_FRAMES + 1))
    return wanted


def pack_pose(points: Sequence) -> np.ndarray:
    """One pose as the app sees it: x mirrored (the picture is shown like a
    mirror), y as is, visibility (0 when the model gives none)."""
    out = np.empty((LANDMARKS, 3), dtype=np.float32)
    for i, point in enumerate(points[:LANDMARKS]):
        visibility = getattr(point, "visibility", None)
        out[i] = (1.0 - point.x, point.y, 0.0 if visibility is None else visibility)
    return out


def track_video(path: Path, wanted: set[int], model: Path) -> tuple[np.ndarray, float, float]:
    import cv2  # noqa: PLC0415 - heavy imports only when videos are processed
    import mediapipe as mp  # noqa: PLC0415
    from mediapipe.tasks import python as mp_tasks  # noqa: PLC0415
    from mediapipe.tasks.python import vision  # noqa: PLC0415

    capture = cv2.VideoCapture(str(path))
    if not capture.isOpened():
        raise RuntimeError(f"could not open {path}")
    fps = capture.get(cv2.CAP_PROP_FPS) or 30.0
    width = capture.get(cv2.CAP_PROP_FRAME_WIDTH)
    height = capture.get(cv2.CAP_PROP_FRAME_HEIGHT)
    options = vision.PoseLandmarkerOptions(
        base_options=mp_tasks.BaseOptions(model_asset_path=str(model)),
        running_mode=vision.RunningMode.VIDEO,
        num_poses=1,
    )
    poses: list[np.ndarray] = []
    empty = np.full((LANDMARKS, 3), np.nan, dtype=np.float32)
    with vision.PoseLandmarker.create_from_options(options) as landmarker:
        index = 0
        while True:
            ok, frame = capture.read()
            if not ok:
                break
            if index in wanted:
                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
                result = landmarker.detect_for_video(image, int(index * 1000 / fps))
                poses.append(pack_pose(result.pose_landmarks[0]) if result.pose_landmarks else empty)
            else:
                poses.append(empty)
            index += 1
    capture.release()
    landmarks = np.stack(poses) if poses else np.empty((0, LANDMARKS, 3), dtype=np.float32)
    return landmarks, float(width / height) if height else 4 / 3, float(fps)


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--videos", type=Path, required=True)
    parser.add_argument("--segmentation", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--list", action="store_true", help="only show which file is used for each video")
    args = parser.parse_args(argv)

    repetitions = read_segmentation(args.segmentation)
    video_ids = sorted({r.video_id for r in repetitions})
    found = find_videos(args.videos, video_ids)
    problems = {k: v for k, v in found.items() if not isinstance(v, Path)}
    for (video_id, camera), where in sorted(found.items()):
        if args.list or not isinstance(where, Path):
            shown = where.relative_to(args.videos) if isinstance(where, Path) else f"!! {where}"
            print(f"{video_id} camera {camera}: {shown}")
    print(f"{len(found) - len(problems)} of {len(found)} videos found")
    if args.list:
        return
    if not args.model.exists():
        raise SystemExit(f"pose model not found: {args.model} (see ml/README.md)")

    args.out.mkdir(parents=True, exist_ok=True)
    todo = [(k, v) for k, v in sorted(found.items()) if isinstance(v, Path)]
    for done, ((video_id, camera), path) in enumerate(todo, start=1):
        target = args.out / f"{video_id}_c{camera}.npz"
        if target.exists():
            continue
        landmarks, aspect, fps = track_video(path, frames_to_track(repetitions, video_id), args.model)
        np.savez_compressed(target, landmarks=landmarks, aspect=aspect, fps=fps)
        seen = np.isfinite(landmarks[:, 0, 0]).sum()
        print(f"[{done}/{len(todo)}] {target.name}: {len(landmarks)} frames, a pose in {seen}")


if __name__ == "__main__":
    main()
