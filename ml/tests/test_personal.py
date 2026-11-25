"""rehab.personal: the personal reference, derived and evaluated the way the
API judges with it."""

import importlib.util

import numpy as np

from rehab import dataset, personal
from rehab._backend import BACKEND
from rehab._backend import personal as api
from tests.helpers import write_segmentation


def test_it_reads_the_channels_the_api_keeps():
    assert dataset.CHANNELS == api.CHANNELS
    assert dataset.STEPS == api.STEPS


def test_the_views_are_the_ones_the_app_films_from():
    path = BACKEND / "migrations" / "versions" / "0015_exercise_camera_view.py"
    spec = importlib.util.spec_from_file_location("m0015", path)
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    assert personal.APP_VIEW == {slug: view for slug, (view, _) in migration.VIEWS.items()}


def recording(tmp_path, values: list[float], camera: int = 17):
    """One arm abduction recording (person 1) of len(values) repetitions:
    every one correct but the last, each measured at one value on every
    channel. Camera 17 is the front view in the helper's segmentation."""
    segmentation = write_segmentation(tmp_path / "Segmentation.csv", people=1, reps_per_video=len(values))
    n, channels = len(values), len(api.CHANNELS)
    data = {
        "x": np.array([np.full((channels, api.STEPS), v / 180, np.float32) for v in values]),
        "mask": np.ones((n, channels, api.STEPS), np.float32),
        "label": np.array([1] * (n - 1) + [0]),
        "exercise": np.zeros(n, int),
        "key": np.array([f"PM_000#{i + 1}" for i in range(n)]),
        "camera": np.full(n, camera),
        "person": np.ones(n, int),
        "split": np.array(["train"] * n),
    }
    return data, segmentation


def test_each_repetition_is_judged_against_its_own_recordings_first_correct_ones(tmp_path):
    data, segmentation = recording(tmp_path, [80.0, 100.0, 90.0, 120.0])

    pairs = personal.Pairs(data, ["arm-abduction"], segmentation, k=2)
    # The first two are the reference (90 degrees) and are not judged.
    assert list(pairs.rows) == [2, 3]
    spreads = dict.fromkeys(personal.own_channels("arm-abduction"), 2.0)
    distance = pairs.distances("arm-abduction", spreads)

    # 0 and 30 degrees off on every channel, in units of a 2-degree spread.
    assert np.allclose(distance, [0, 15], atol=1e-3)


def test_repetitions_filmed_from_the_wrong_side_are_left_out(tmp_path):
    data, segmentation = recording(tmp_path, [80.0, 100.0, 90.0, 120.0], camera=18)

    pairs = personal.Pairs(data, ["arm-abduction"], segmentation, k=2)

    assert len(pairs.rows) == 0


def test_the_exercises_channels_are_their_templates_joints_and_checks():
    path = BACKEND / "migrations" / "versions" / "0003_exercise_templates_and_plans.py"
    spec = importlib.util.spec_from_file_location("m0003", path)
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    shipped = {
        e["slug"]: (tuple(e["target_joints"]), tuple(c["key"] for c in e["checks"]))
        for e in migration.DEFAULT_EXERCISES
    }
    assert personal.TARGETS == shipped


def test_the_cut_is_the_one_that_best_balances_both_kinds():
    distance = np.array([1.0, 2.0, 3.0, 9.0, 10.0])
    label = np.array([1, 1, 1, 0, 0])

    assert personal.best_cut(distance, label) == 3.0
    # Of cuts that do equally well, the strictest.
    assert personal.best_cut(np.array([1.0, 2.0, 3.0, 2.5]), np.array([1, 1, 1, 0])) == 2.0
