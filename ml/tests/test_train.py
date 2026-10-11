# Training and the traceable model record (SCRUM-47, SCRUM-48). Needs PyTorch.
import json

import numpy as np
import pytest

torch = pytest.importorskip("torch")

from rehab import train  # noqa: E402


def _toy_dataset(path, examples=60, channels=17, steps=8):
    rng = np.random.default_rng(0)
    label = np.tile([0, 1], examples // 2)
    x = rng.normal(0.5, 0.05, (examples, channels, steps)).astype(np.float32)
    x[label == 0, 0, :] += 0.4  # incorrect repetitions differ in one channel
    split = np.array(["train"] * (examples - 20) + ["val"] * 10 + ["test"] * 10)
    np.savez_compressed(
        path,
        x=x,
        mask=np.ones_like(x),
        exercise=rng.integers(0, 5, examples),
        label=label,
        person=np.zeros(examples, dtype=int),
        split=split,
        key=np.array([f"k{i}" for i in range(examples)]),
        camera=np.full(examples, 17),
    )
    manifest = {
        "dataset": "toy",
        "segmentation_sha256": "a",
        "splits_sha256": "b",
        "landmarks_sha256": "c",
        "dataset_sha256": "d",
        "examples": {"train": examples - 20, "val": 10, "test": 10},
        "channels": [f"c{i}" for i in range(channels)],
        "steps": steps,
        "exercises": ["arm-abduction", "push-ups", "leg-abduction", "leg-lunge", "squats"],
    }
    path.with_suffix(".json").write_text(json.dumps(manifest))
    return path


def test_a_trained_model_is_written_with_its_evaluation_and_data(tmp_path):
    data = _toy_dataset(tmp_path / "reps.npz")
    target = train.train(data, tmp_path / "models", {"epochs": 15}, tmp_path / "model_records")
    record = json.loads((target / "record.json").read_text())
    # A copy of the record, to be committed, without the weights.
    assert json.loads((tmp_path / "model_records" / f"{target.name}.json").read_text()) == record

    assert (target / "model.pt").exists()
    assert record["model_version"] == target.name
    assert record["weights_sha256"][:8] in record["model_version"]
    for key in ("segmentation_sha256", "splits_sha256", "landmarks_sha256", "dataset_sha256"):
        assert record["training_data"][key]
    assert {"agreement", "balanced_accuracy", "by_exercise"} <= set(record["test"])
    assert record["test"]["repetitions"] == 10
    # The toy task is easy: the model must have learnt something.
    assert record["validation"]["balanced_accuracy"] > 0.8


def test_training_is_repeatable(tmp_path):
    data = _toy_dataset(tmp_path / "reps.npz")
    first = train.train(data, tmp_path / "a", {"epochs": 5})
    second = train.train(data, tmp_path / "b", {"epochs": 5})
    a = torch.load(first / "model.pt")
    b = torch.load(second / "model.pt")
    assert a.keys() == b.keys()
    assert all(torch.equal(a[k], b[k]) for k in a)
