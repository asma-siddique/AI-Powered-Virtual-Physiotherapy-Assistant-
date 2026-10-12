# Packaging a model for the API and scoring it on the held-out subjects
# (user stories 4.1 and 4.3). Needs PyTorch.
import base64
import hashlib
import json

import numpy as np
import pytest

torch = pytest.importorskip("torch")

from rehab import dataset, evaluate, export, splits, train  # noqa: E402
from rehab._backend import classifier, scoring  # noqa: E402
from tests.helpers import write_landmarks, write_segmentation  # noqa: E402


@pytest.fixture(scope="module")
def trained(tmp_path_factory):
    """A small dataset in the real formats, and a model trained on it."""
    root = tmp_path_factory.mktemp("rehab")
    segmentation = write_segmentation(root / "Segmentation.csv", people=10, reps_per_video=4)
    split_path = root / "splits.json"
    splits.main(["--segmentation", str(segmentation), "--out", str(split_path)])
    landmarks = root / "landmarks"
    landmarks.mkdir()
    # 10 people x 6 exercises; deep knee bends for every second person, so
    # the examples are not all alike.
    for video in range(60):
        write_landmarks(landmarks / f"PM_{video:03d}_c17.npz", frames=180, knee=180 if video % 2 else 70)
    data = root / "reps.npz"
    dataset.main(
        [
            "--segmentation", str(segmentation), "--splits", str(split_path),
            "--landmarks", str(landmarks), "--out", str(data),
        ]
    )  # fmt: skip
    model_dir = train.train(data, root / "models", {"epochs": 3})
    return {
        "segmentation": segmentation,
        "splits": split_path,
        "landmarks": landmarks,
        "data": data,
        "model": model_dir,
    }


def test_the_api_resamples_a_repetition_exactly_as_the_training_data_was():
    rng = np.random.default_rng(1)
    series = rng.uniform(0, 180, (47, 17)).astype(np.float32)
    series[rng.uniform(0, 1, series.shape) < 0.3] = np.nan
    series[:, 4] = np.nan  # a channel never measured

    ours = classifier.resample(series, dataset.STEPS)
    theirs = dataset.resample(series, dataset.STEPS)

    np.testing.assert_array_equal(ours[0], theirs[0])
    np.testing.assert_array_equal(ours[1], theirs[1])


def test_an_exported_model_answers_as_pytorch_does(trained):
    target = export.export(trained["model"], trained["splits"])

    registration = json.loads(target.read_text())
    record = registration["record"]
    weights = base64.b64decode(registration["weights_b64"])
    assert hashlib.sha256(weights).hexdigest() == registration["weights_sha256"]
    assert weights == (trained["model"] / "serving.npz").read_bytes()
    # The splits travel with the model, so the API can check them itself.
    assert (
        hashlib.sha256(registration["splits"].encode()).hexdigest()
        == record["training_data"]["splits_sha256"]
    )
    served = classifier.load(weights)
    assert served.channels == dataset.CHANNELS
    assert served.source_sha256 == record["weights_sha256"]
    assert export.largest_difference(trained["model"], served, record) <= export.TOLERANCE


def test_a_model_is_not_exported_with_other_splits_than_it_was_trained_with(trained, tmp_path):
    other = tmp_path / "splits.json"
    other.write_text(trained["splits"].read_text().replace("\n", "\n ", 1))

    with pytest.raises(SystemExit, match="not the splits"):
        export.export(trained["model"], other)


def test_a_model_that_would_answer_differently_is_not_exported(trained, monkeypatch):
    monkeypatch.setattr(export, "BN_EPS", 0.5)  # a wrong export
    (trained["model"] / "registration.json").unlink(missing_ok=True)

    with pytest.raises(SystemExit, match="answers differently"):
        export.export(trained["model"], trained["splits"])

    assert not (trained["model"] / "registration.json").exists()


def test_the_exported_model_scores_the_test_subjects_as_training_recorded(trained):
    export.export(trained["model"], trained["splits"])
    record = json.loads((trained["model"] / "record.json").read_text())

    result = evaluate.run(trained["data"], trained["model"])

    assert result["model_version"] == record["model_version"]
    assert result["eval_set"] == classifier.eval_set_name(record["training_data"])
    assert result["metrics"]["repetitions"] == record["test"]["repetitions"]
    assert result["metrics"]["confusion"] == record["test"]["confusion"]


def test_the_rule_is_scored_on_the_same_repetitions(trained):
    record = json.loads((trained["model"] / "record.json").read_text())

    result = evaluate.run(
        trained["data"], segmentation=trained["segmentation"], landmarks=trained["landmarks"]
    )

    assert result["model_version"] == scoring.VERSION
    # The same held-out set as the classifier's, so the two can be compared.
    assert result["eval_set"] == classifier.eval_set_name(record["training_data"])
    assert result["metrics"]["repetitions"] == record["test"]["repetitions"]
    assert 0 <= result["metrics"]["agreement"] <= 1


def test_the_rule_needs_the_frames_it_judges(trained):
    with pytest.raises(SystemExit, match="--segmentation and --landmarks"):
        evaluate.run(trained["data"])


def test_the_rule_is_given_what_the_app_would_have_measured():
    lean, depth = dataset.CHANNELS.index("trunk_lean"), dataset.CHANNELS.index("depth")
    series = np.full((6, len(dataset.CHANNELS)), np.nan, dtype=np.float32)
    # One wild frame (40) between steady ones is not what the trunk "held".
    series[:, lean] = [2, 3, 40, 4, 12, 13]
    series[:, depth] = [170, 140, 100, 100, 150, 175]
    checks = [{"key": "trunk_lean"}, {"key": "depth"}, {"key": "knee_valgus"}]

    measures = evaluate.rule_measures(series, "squats", checks)

    assert measures["trunk_lean"] == 12  # the middle of 4, 12, 13
    # The lowest point held was 100 degrees: 10 short of the 90 degree target.
    assert measures["depth"] == 10
    # Never in view: not measured, not guessed.
    assert measures["knee_valgus"] is None


def test_the_rule_reads_the_thresholds_the_app_ships_with():
    checks = evaluate.default_checks()

    assert set(checks) >= set(dataset.SLUGS)
    assert all({"key", "info", "amber"} <= set(check) for check in checks["arm-abduction"])
