# Finding the videos and packing poses the way the app does.
from types import SimpleNamespace

import numpy as np

from rehab.extract import find_videos, frames_to_track, pack_pose
from rehab.segmentation import read_segmentation
from tests.helpers import write_segmentation


def test_videos_are_found_under_common_naming_schemes(tmp_path):
    for name in [
        "PM_000-c17.mp4",
        "PM_000-c18.mp4",
        "cam17/PM_001.avi",
        "cam18/PM_001.avi",
        "PM_117a_Camera17.mp4",
    ]:
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"")
    found = find_videos(tmp_path, ["PM_000", "PM_001", "PM_117a", "PM_002"])
    assert found[("PM_000", 17)].name == "PM_000-c17.mp4"
    assert found[("PM_000", 18)].name == "PM_000-c18.mp4"
    assert found[("PM_001", 18)].parent.name == "cam18"
    assert found[("PM_117a", 17)].name == "PM_117a_Camera17.mp4"
    assert found[("PM_117a", 18)] == "no file found"
    assert found[("PM_002", 17)] == "no file found"


def test_poses_are_mirrored_like_the_app_and_missing_visibility_is_zero():
    points = [SimpleNamespace(x=0.2, y=0.3, visibility=0.9)] * 32 + [
        SimpleNamespace(x=0.6, y=0.7, visibility=None)
    ]
    pose = pack_pose(points)
    assert pose.shape == (33, 3)
    np.testing.assert_allclose(pose[0], [0.8, 0.3, 0.9], rtol=1e-6)
    np.testing.assert_allclose(pose[32], [0.4, 0.7, 0.0], rtol=1e-6)


def test_only_frames_around_repetitions_are_tracked(tmp_path):
    reps = read_segmentation(
        write_segmentation(tmp_path / "s.csv", people=1, reps_per_video=2, frames_per_rep=40)
    )
    wanted = frames_to_track(reps, "PM_000")
    assert min(wanted) == 0 and max(wanted) == 89 + 15
    assert frames_to_track(reps, "PM_999") == set()
