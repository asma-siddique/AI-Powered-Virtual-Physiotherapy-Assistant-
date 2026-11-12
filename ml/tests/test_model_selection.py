# Choosing the training settings without the test subjects, augmentation,
# and deriving feedback thresholds from labels (stories 3.4 and 4.1).
import json

import numpy as np
import pytest

from rehab import thresholds
from rehab.crossval import subject_folds
from rehab.train import mirror_pairs, mirrored

CHANNELS = ["left_shoulder", "right_shoulder", "left_elbow", "right_elbow", "trunk_lean"]


def test_folds_hold_every_non_test_subject_once_and_never_a_test_one():
    person = np.repeat([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], [120, 110, 120, 115, 117, 106, 115, 122, 127, 8])
    split = np.where(np.isin(person, [2, 4]), "test", "train")

    groups = subject_folds(person, split)

    flat = [p for g in groups for p in g]
    assert sorted(flat) == [1, 3, 5, 6, 7, 8, 9, 10]
    assert 2 not in flat and 4 not in flat
    sizes = [sum(int((person == p).sum()) for p in g) for g in groups]
    # About the same number of examples in each group.
    assert max(sizes) - min(sizes) <= 130


def test_a_mirrored_repetition_swaps_left_and_right_and_keeps_the_checks():
    x = np.arange(2 * 5 * 3, dtype=np.float32).reshape(2, 5, 3)
    mask = np.ones_like(x)
    mask[:, 0] = 0  # the left shoulder was not seen

    x2, m2 = mirrored(x, mask, mirror_pairs(CHANNELS))

    assert mirror_pairs(CHANNELS) == [(0, 1), (2, 3)]
    np.testing.assert_array_equal(x2[:, 0], x[:, 1])
    np.testing.assert_array_equal(x2[:, 1], x[:, 0])
    np.testing.assert_array_equal(x2[:, 4], x[:, 4])
    np.testing.assert_array_equal(m2[:, 1], mask[:, 0])
    # The originals are untouched.
    assert mask[:, 0].sum() == 0 and x[0, 0, 0] == 0


def check(key="trunk_lean", info=5.0, amber=10.0, red=20.0):
    return {
        "key": key,
        "label": key,
        "info": info,
        "amber": amber,
        "red": red,
        "corrective_message": "Stand tall.",
    }


def test_amber_moves_to_where_the_labels_change():
    rng = np.random.default_rng(0)
    # Correct repetitions lean up to about 15 degrees, incorrect ones about 25.
    correct = rng.uniform(2, 15, 200)
    incorrect = rng.uniform(19, 30, 200)
    measures = [{"trunk_lean": float(v)} for v in np.concatenate([correct, incorrect])]
    labels = np.array([1] * 200 + [0] * 200)

    new, report = thresholds.derive_exercise(measures, labels, [check(amber=10.0, red=20.0)])

    amber = new[0]["amber"]
    assert 15 <= amber <= 19.5
    assert report["balanced_accuracy_after"] > report["balanced_accuracy_before"]
    assert report["balanced_accuracy_after"] > 0.95
    # INFO stays under AMBER; thresholds are in half degrees.
    assert new[0]["info"] < amber
    assert amber * 2 == int(amber * 2)


def test_red_is_kept_unless_amber_would_reach_it():
    measures = [{"trunk_lean": v} for v in [5.0] * 50 + [30.0] * 50]
    labels = np.array([1] * 50 + [0] * 50)

    new, _ = thresholds.derive_exercise(measures, labels, [check(amber=10.0, red=12.0)])

    # AMBER moved up past the old RED: RED keeps its old 2 degree distance above it.
    assert new[0]["red"] == new[0]["amber"] + 2.0
    no_red, _ = thresholds.derive_exercise(measures, labels, [check(red=None)])
    assert no_red[0]["red"] is None


def test_an_unmeasured_check_never_counts_against_a_repetition():
    measures = [{"trunk_lean": None}] * 10 + [{"trunk_lean": 3.0}] * 10
    labels = np.array([1] * 20)

    new, report = thresholds.derive_exercise(measures, labels, [check()])

    assert report["balanced_accuracy_after"] == pytest.approx(1.0)
    assert new[0]["amber"] > 3.0


def test_training_from_a_crossval_report_records_how_it_was_chosen(tmp_path):
    pytest.importorskip("torch")
    from rehab import train
    from tests.test_train import _toy_dataset

    data = _toy_dataset(tmp_path / "reps.npz")
    report = {
        "folds": [[1], [2]],
        "winner": {"name": "mirror", "settings": {}, "epoch": 2, "agreement": 0.8, "balanced_accuracy": 0.79},
        "candidates": {"mirror": {"best": {"epoch": 2, "agreement": 0.8, "balanced_accuracy": 0.79}}},
    }
    path = tmp_path / "crossval.json"
    path.write_text(json.dumps(report))

    train.main(
        [
            "--data",
            str(data),
            "--out",
            str(tmp_path / "models"),
            "--records",
            str(tmp_path / "records"),
            "--from-crossval",
            str(path),
        ]
    )

    [record_file] = (tmp_path / "records").glob("*.json")
    record = json.loads(record_file.read_text())
    assert record["settings"]["fit_on_validation"] is True
    assert record["settings"]["epochs"] == 3
    assert record["validation"] is None  # those subjects were trained on
    assert record["cross_validation"]["winner"] == "mirror"
    assert record["selection"].startswith("cross-validation")
    assert record["test"]["repetitions"] == 10


def test_each_check_is_read_only_in_the_view_where_it_means_what_it_says():
    # Camera 18 stands at a right angle to camera 17.
    assert thresholds.view_of(17, "front") == "front"
    assert thresholds.view_of(18, "front") == "side"
    assert thresholds.view_of(17, "profile") == "side"
    assert thresholds.view_of(18, "profile") == "front"
    assert thresholds.view_of(17, "half-profile") == "oblique"

    squat = {"knee_valgus": 95.0, "trunk_lean": 30.0, "depth": 12.0}
    # From the side, "knee valgus" is really knee bend: it is left out.
    assert thresholds.in_view(squat, "squats", "side") == {
        "knee_valgus": None,
        "trunk_lean": 30.0,
        "depth": 12.0,
    }
    assert thresholds.in_view(squat, "squats", "front") == {
        "knee_valgus": 95.0,
        "trunk_lean": None,
        "depth": None,
    }
    # For the abductions trunk lean is a sideways lean, seen from the front.
    assert thresholds.in_view({"trunk_lean": 4.0}, "arm-abduction", "front") == {"trunk_lean": 4.0}
    assert thresholds.in_view({"trunk_lean": 4.0}, "arm-abduction", "oblique") == {"trunk_lean": None}
