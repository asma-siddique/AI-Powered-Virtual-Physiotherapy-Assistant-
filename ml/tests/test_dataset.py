# Turning repetitions into training examples with the app's own features.
import json

import numpy as np
import pytest

from rehab import dataset, splits
from tests.helpers import standing_pose, write_landmarks, write_segmentation


def test_frames_are_measured_with_the_apps_feature_code():
    straight = dataset.frame_vector(standing_pose(4 / 3), aspect=4 / 3, slug="squats")
    knee = dataset.CHANNELS.index("left_knee")
    depth = dataset.CHANNELS.index("depth")
    assert straight[knee] == pytest.approx(180, abs=1e-3)
    assert straight[depth] == pytest.approx(180, abs=1e-3)

    bent = dataset.frame_vector(standing_pose(16 / 9, knee=90), aspect=16 / 9, slug="squats")
    assert bent[knee] == pytest.approx(90, abs=1e-3)
    # The aspect ratio matters: the same picture read as square is skewed.
    skewed = dataset.frame_vector(standing_pose(16 / 9, knee=90), aspect=1.0, slug="squats")
    assert abs(skewed[knee] - 90) > 1

    # Depth is not a check of Leg Lunge, so it is not measured, not guessed.
    lunge = dataset.frame_vector(standing_pose(4 / 3), aspect=4 / 3, slug="leg-lunge")
    assert np.isnan(lunge[depth])
    # Nobody in the picture: nothing is measured.
    assert np.isnan(dataset.frame_vector(np.full((33, 3), np.nan), aspect=1.0, slug="squats")).all()


def test_resampling_interpolates_what_was_measured_and_masks_the_rest():
    series = np.array(
        [[0.0, np.nan, np.nan], [90.0, np.nan, 10.0], [180.0, np.nan, np.nan]], dtype=np.float32
    )
    values, mask = dataset.resample(series, steps=5)
    np.testing.assert_allclose(values[0] * 180, [0, 45, 90, 135, 180], atol=1e-4)
    assert mask[0].tolist() == [1, 1, 1, 1, 1]
    # A channel never measured is zeros with mask 0.
    assert values[1].tolist() == [0] * 5 and mask[1].tolist() == [0] * 5
    # Measured once: its value everywhere, but only marked where it was seen.
    np.testing.assert_allclose(values[2] * 180, [10] * 5, atol=1e-4)
    assert mask[2].tolist() == [0, 0, 1, 0, 0]


@pytest.fixture
def prepared(tmp_path):
    segmentation = write_segmentation(tmp_path / "Segmentation.csv", people=10, reps_per_video=2)
    split_path = tmp_path / "splits.json"
    splits.main(["--segmentation", str(segmentation), "--out", str(split_path)])
    landmarks = tmp_path / "landmarks"
    landmarks.mkdir()
    # Every video of person 1 (6 exercises, ids 0-5) from camera 17; the arm VW
    # video (id 1) is never used. One squat repetition has no pose at all.
    for video in range(6):
        write_landmarks(
            landmarks / f"PM_{video:03d}_c17.npz", frames=100, missing=range(50, 90) if video == 5 else ()
        )
    return segmentation, split_path, landmarks


def test_examples_are_built_per_repetition_and_camera(prepared):
    segmentation, split_path, landmarks = prepared
    arrays, manifest = dataset.build(segmentation, split_path, landmarks, steps=8)
    # 5 supported exercises x 2 repetitions, minus the squat repetition with no pose.
    assert len(arrays["label"]) == 9
    assert arrays["x"].shape == (9, len(dataset.CHANNELS), 8)
    assert arrays["mask"].shape == arrays["x"].shape
    assert manifest["skipped"] == {"no pose in most frames": 1}
    assert set(arrays["person"]) == {1}
    assert set(arrays["camera"]) == {17}
    # Every example carries the split of its subject.
    record = json.loads(split_path.read_text())
    which = splits.split_of(record)
    assert set(arrays["split"]) == {which[1]}
    assert "PM_006" in manifest["videos_without_landmarks"]
    assert manifest["channels"] == list(dataset.CHANNELS)


def test_splits_from_another_annotation_file_are_refused(prepared, tmp_path):
    segmentation, split_path, landmarks = prepared
    segmentation.write_text(segmentation.read_text() + "\n")
    with pytest.raises(SystemExit, match="different Segmentation.csv"):
        dataset.build(segmentation, split_path, landmarks)
