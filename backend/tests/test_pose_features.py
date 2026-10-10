# US 3.2 (SCRUM-53): per-exercise joint-angle features. The same cases are
# checked against the app's Dart version in frontend/test/pose_features_test.dart.
import importlib.util
import json
import time
from pathlib import Path

import pytest

from app.pose_features import CHECKS, frame_features

FIXTURE = json.loads((Path(__file__).parent / "fixtures" / "pose_feature_cases.json").read_text())
TOLERANCE = FIXTURE["tolerance_degrees"]


def _run(case: dict, *, aspect_ratio: float | None = None):
    return frame_features(
        case["landmarks"],
        aspect_ratio=aspect_ratio or case["aspect_ratio"],
        exercise_slug=case["exercise_slug"],
        target_joints=case["target_joints"],
        check_keys=case["check_keys"],
        min_visibility=FIXTURE["min_visibility"],
    )


def _assert_close(got: dict, expected: dict) -> None:
    assert set(got) == set(expected)
    for key, want in expected.items():
        if want is None:
            assert got[key] is None, key
        else:
            assert got[key] == pytest.approx(want, abs=TOLERANCE), key


@pytest.mark.parametrize("case", FIXTURE["cases"], ids=lambda c: c["name"])
def test_shared_case(case):
    features = _run(case)
    _assert_close(features.joint_angles, case["expected"]["joint_angles"])
    _assert_close(features.checks, case["expected"]["checks"])
    assert features.unsupported == case["expected"]["unsupported"]


def _case(name: str) -> dict:
    return next(c for c in FIXTURE["cases"] if c["name"] == name)


def test_ignoring_the_aspect_ratio_would_skew_the_angles():
    # The same squat measured as if the camera were square: the knee is no
    # longer 90 degrees. This is why x is scaled before any angle is taken.
    case = _case("squat_side_knee_90_trunk_30")
    skewed = _run(case, aspect_ratio=1.0)
    assert abs(skewed.joint_angles["right_knee"] - 90) > 1


def test_a_landmark_below_the_visibility_threshold_is_never_used():
    case = json.loads(json.dumps(_case("lunge_front_left_knee_valgus_20")))
    case["landmarks"]["left_knee"][2] = FIXTURE["min_visibility"] - 0.01
    features = _run(case)
    assert features.joint_angles["left_knee"] is None
    assert features.joint_angles["left_hip"] is None
    # The right knee is still measured, and it is not valgus.
    assert features.checks["knee_valgus"] == pytest.approx(0, abs=TOLERANCE)


def _seeded_exercises() -> list[dict]:
    """The five exercises as the 0003 migration inserts them."""
    path = next((Path(__file__).parents[1] / "migrations" / "versions").glob("0003_*.py"))
    spec = importlib.util.spec_from_file_location("migration_0003", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.DEFAULT_EXERCISES


def test_every_check_in_the_seeded_templates_is_supported():
    exercises = _seeded_exercises()
    assert len(exercises) == 5
    for exercise in exercises:
        features = frame_features(
            {},
            aspect_ratio=1.0,
            exercise_slug=exercise["slug"],
            target_joints=exercise["target_joints"],
            check_keys=[check["key"] for check in exercise["checks"]],
        )
        assert features.unsupported == [], exercise["slug"]


def test_known_checks_are_listed():
    seeded = ["trunk_lean", "elbow_bend", "knee_bend", "knee_valgus", "knee_forward", "hip_sag", "depth"]
    assert set(seeded) <= set(CHECKS)


def test_a_frame_takes_well_under_ten_milliseconds():
    case = _case("squat_side_knee_90_trunk_30")
    runs = 500
    start = time.perf_counter()
    for _ in range(runs):
        _run(case)
    per_frame_ms = (time.perf_counter() - start) * 1000 / runs
    assert per_frame_ms < 10
