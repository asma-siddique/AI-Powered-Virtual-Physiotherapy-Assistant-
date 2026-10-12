"""Packaging a trained model for the API (user stories 4.1 and 4.3).

The API does not have PyTorch. It runs the network with NumPy from plain
arrays (backend/app/classifier.py), so a trained model is exported once:

    python -m rehab.export --model models/<version> --splits splits/rehab24_splits.json

writes, next to the model's weights,

- serving.npz: the weights as plain arrays, with batch normalisation folded
  into a scale and a shift per filter;
- registration.json: the model's record, the splits it was trained with and
  the exported weights, ready to be registered by an admin in the app
  (Admin > Scoring models > Register).

Before anything is written, the exported arrays are run on random
repetitions and held to PyTorch's own output: a model that would answer
differently in the API is never exported.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
from collections.abc import Sequence
from pathlib import Path

import numpy as np

from rehab._backend import classifier
from rehab.train import _build_model

# How far the API's answer may be from PyTorch's, as a probability.
TOLERANCE = 1e-5
BN_EPS = 1e-5


def _fold(state: dict, name: str) -> tuple[np.ndarray, np.ndarray]:
    """Batch normalisation at inference is a scale and a shift per filter."""
    scale = state[f"{name}.weight"] / np.sqrt(state[f"{name}.running_var"] + BN_EPS)
    return scale, state[f"{name}.bias"] - state[f"{name}.running_mean"] * scale


def serving_arrays(state: dict) -> dict[str, np.ndarray]:
    """The network's weights under the names the API reads."""
    state = {name: np.asarray(value, dtype=np.float32) for name, value in state.items()}
    bn1_scale, bn1_shift = _fold(state, "features.1")
    bn2_scale, bn2_shift = _fold(state, "features.4")
    return {
        "conv1_weight": state["features.0.weight"],
        "conv1_bias": state["features.0.bias"],
        "bn1_scale": bn1_scale,
        "bn1_shift": bn1_shift,
        "conv2_weight": state["features.3.weight"],
        "conv2_bias": state["features.3.bias"],
        "bn2_scale": bn2_scale,
        "bn2_shift": bn2_shift,
        "fc1_weight": state["head.0.weight"],
        "fc1_bias": state["head.0.bias"],
        "fc2_weight": state["head.3.weight"],
        "fc2_bias": state["head.3.bias"],
    }


def largest_difference(
    model_dir: Path, served: classifier.Classifier, record: dict, examples: int = 64
) -> float:
    """The largest gap between PyTorch's answer and the API's, over random
    repetitions of every exercise, with parts of them unmeasured."""
    import torch  # noqa: PLC0415

    data = record["training_data"]
    channels, names, steps = len(data["channels"]), data["exercises"], data["steps"]
    network = _build_model(channels, len(names), record["settings"]["hidden"], record["settings"]["dropout"])
    network.load_state_dict(torch.load(model_dir / "model.pt"))
    network.eval()
    rng = np.random.default_rng(0)
    values = rng.uniform(0, 1, (examples, channels, steps)).astype(np.float32)
    mask = (rng.uniform(0, 1, (examples, channels, steps)) > 0.2).astype(np.float32)
    values *= mask
    which = rng.integers(0, len(names), examples)
    onehot = np.eye(len(names), dtype=np.float32)[which]
    with torch.no_grad():
        expected = torch.sigmoid(
            network(torch.from_numpy(values), torch.from_numpy(mask), torch.from_numpy(onehot))
        ).numpy()
    got = np.array([served.probability_correct(values[i], mask[i], names[which[i]]) for i in range(examples)])
    return float(np.abs(expected - got).max())


def export(model_dir: Path, splits: Path) -> Path:
    import torch  # noqa: PLC0415

    record = json.loads((model_dir / "record.json").read_text())
    data = record["training_data"]
    splits_text = splits.read_bytes().decode()
    if hashlib.sha256(splits_text.encode()).hexdigest() != data["splits_sha256"]:
        raise SystemExit(f"{splits} is not the splits file {record['model_version']} was trained with")
    weights_file = model_dir / "model.pt"
    if hashlib.sha256(weights_file.read_bytes()).hexdigest() != record["weights_sha256"]:
        raise SystemExit(f"{weights_file} is not the weights its record describes")

    state = {name: value.numpy() for name, value in torch.load(weights_file).items()}
    meta = {
        "model_version": record["model_version"],
        "source_weights_sha256": record["weights_sha256"],
        "channels": data["channels"],
        "exercises": data["exercises"],
        "steps": data["steps"],
    }
    out = io.BytesIO()
    np.savez(out, meta=np.array(json.dumps(meta)), **serving_arrays(state))
    served_bytes = out.getvalue()

    # Read back exactly as the API will read it, and held to PyTorch.
    served = classifier.load(served_bytes)
    difference = largest_difference(model_dir, served, record)
    if difference > TOLERANCE:
        raise SystemExit(
            f"the exported model answers differently from PyTorch (by up to {difference:.2e}); "
            "nothing written"
        )

    (model_dir / "serving.npz").write_bytes(served_bytes)
    registration = {
        "record": record,
        "splits": splits_text,
        "weights_b64": base64.b64encode(served_bytes).decode(),
        "weights_sha256": classifier.sha256(served_bytes),
    }
    target = model_dir / "registration.json"
    target.write_text(json.dumps(registration) + "\n")
    print(f"{record['model_version']}: the API's answers match PyTorch's to within {difference:.1e}")
    print(f"written {target} ({target.stat().st_size / 1024:.0f} kB)")
    return target


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--model", type=Path, required=True, help="models/<version>")
    parser.add_argument("--splits", type=Path, required=True)
    args = parser.parse_args(argv)
    export(args.model, args.splits)


if __name__ == "__main__":
    main()
