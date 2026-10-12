"""Running a trained correctness classifier inside the API (US 4.1).

The network is trained with PyTorch in ``ml/`` and exported as plain arrays
(``ml/rehab/export.py``). Here it is evaluated with NumPy only, so the API
does not need PyTorch installed: two 1-D convolutions with batch
normalisation, pooled over time, joined with which exercise it is, then two
linear layers. ``ml/tests/test_export.py`` holds this to the PyTorch model's
own output.

A repetition goes in as it does in training: every channel resampled to a
fixed number of steps and divided by 180, with a mask of what was really
measured.
"""

import hashlib
import io
import json
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any

import numpy as np

# Angles are fed to the network as fractions of a straight line.
ANGLE_SCALE = 180.0

# What a served model must be able to say about itself.
_REQUIRED = (
    "conv1_weight",
    "conv1_bias",
    "bn1_scale",
    "bn1_shift",
    "conv2_weight",
    "conv2_bias",
    "bn2_scale",
    "bn2_shift",
    "fc1_weight",
    "fc1_bias",
    "fc2_weight",
    "fc2_bias",
    "meta",
)


class ModelFormatError(ValueError):
    """The uploaded weights are not a model this API can run."""


def _conv1d(x: np.ndarray, weight: np.ndarray, bias: np.ndarray) -> np.ndarray:
    """(channels, steps) -> (filters, steps), padded so the length is kept."""
    filters, channels, kernel = weight.shape
    pad = kernel // 2
    padded = np.pad(x, ((0, 0), (pad, pad)))
    # Every window of `kernel` steps, as (steps, channels, kernel).
    windows = np.lib.stride_tricks.sliding_window_view(padded, kernel, axis=1).transpose(1, 0, 2)
    return np.tensordot(windows, weight, axes=([1, 2], [1, 2])).T + bias[:, None]


def resample(series: np.ndarray, steps: int) -> tuple[np.ndarray, np.ndarray]:
    """(frames x channels), NaN where not measured -> values and mask, both
    (channels x steps), exactly as the training data is built
    (ml/rehab/dataset.py; ml/tests/test_export.py holds the two together).

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


def eval_set_name(training_data: Mapping[str, Any]) -> str:
    """Names a held-out set: the test subjects of one split of one built
    dataset. Two evaluations with the same name scored the same repetitions,
    so their results can be compared."""
    return (
        f"{training_data['dataset']}:test:{str(training_data['splits_sha256'])[:16]}"
        f":{str(training_data.get('dataset_sha256') or '')[:16]}"
    )


@dataclass(frozen=True)
class Classifier:
    arrays: dict[str, np.ndarray]
    channels: tuple[str, ...]
    exercises: tuple[str, ...]
    steps: int
    # Checksum of the PyTorch weights these arrays were exported from, as it
    # stands in the model's training record.
    source_sha256: str | None = None

    def judge(self, frames: Sequence[Sequence[float | None]], exercise: str) -> float | None:
        """How likely a repetition was done correctly, from what was measured
        in each of its frames (one value per channel, None where it could not
        be measured)."""
        series = np.array(
            [[np.nan if value is None else value for value in frame] for frame in frames], dtype=np.float32
        )
        values, mask = resample(series, self.steps)
        return self.probability_correct(values, mask, exercise)

    def probability_correct(self, values: np.ndarray, mask: np.ndarray, exercise: str) -> float | None:
        """How likely the repetition was done correctly, 0 to 1. None for an
        exercise the model was not trained on."""
        if exercise not in self.exercises:
            return None
        a = self.arrays
        x = np.concatenate([values, mask]).astype(np.float32)
        h = _conv1d(x, a["conv1_weight"], a["conv1_bias"])
        h = np.maximum(h * a["bn1_scale"][:, None] + a["bn1_shift"][:, None], 0)
        h = _conv1d(h, a["conv2_weight"], a["conv2_bias"])
        h = np.maximum(h * a["bn2_scale"][:, None] + a["bn2_shift"][:, None], 0)
        onehot = np.zeros(len(self.exercises), dtype=np.float32)
        onehot[self.exercises.index(exercise)] = 1
        joined = np.concatenate([h.mean(axis=1), h.max(axis=1), onehot])
        hidden = np.maximum(a["fc1_weight"] @ joined + a["fc1_bias"], 0)
        logit = float((a["fc2_weight"] @ hidden + a["fc2_bias"])[0])
        return float(1 / (1 + np.exp(-logit)))


def sha256(weights: bytes) -> str:
    return hashlib.sha256(weights).hexdigest()


def load(weights: bytes) -> Classifier:
    """Reads exported weights, refusing anything that is not a complete
    model of the expected shape."""
    try:
        # allow_pickle stays off: the file is data, never code.
        with np.load(io.BytesIO(weights), allow_pickle=False) as archive:
            arrays = {name: archive[name] for name in archive.files}
    except Exception as exc:
        raise ModelFormatError("The weights file could not be read.") from exc
    missing = [name for name in _REQUIRED if name not in arrays]
    if missing:
        raise ModelFormatError(f"The weights file is missing: {', '.join(missing)}.")
    try:
        meta = json.loads(str(arrays.pop("meta")))
        channels = tuple(meta["channels"])
        exercises = tuple(meta["exercises"])
        steps = int(meta["steps"])
    except (ValueError, KeyError, TypeError) as exc:
        raise ModelFormatError("The weights file does not describe its inputs.") from exc
    arrays = {name: np.asarray(value, dtype=np.float32) for name, value in arrays.items()}
    hidden = arrays["conv1_weight"].shape[0]
    expected = {
        "conv1_weight": (hidden, 2 * len(channels), arrays["conv1_weight"].shape[2]),
        "conv2_weight": (hidden, hidden, arrays["conv2_weight"].shape[2]),
        "fc1_weight": (arrays["fc1_weight"].shape[0], 2 * hidden + len(exercises)),
        "fc2_weight": (1, arrays["fc1_weight"].shape[0]),
    }
    for name, shape in expected.items():
        if arrays[name].shape != shape:
            raise ModelFormatError(f"{name} has shape {arrays[name].shape}, expected {shape}.")
    if not channels or not exercises or steps < 2:
        raise ModelFormatError("The weights file does not describe its inputs.")
    if any(not np.isfinite(value).all() for value in arrays.values()):
        raise ModelFormatError("The weights contain values that are not numbers.")
    source = meta.get("source_weights_sha256")
    return Classifier(
        arrays=arrays,
        channels=channels,
        exercises=exercises,
        steps=steps,
        source_sha256=str(source) if source else None,
    )


_loaded: dict[str, Classifier] = {}


def cached(digest: str, fetch: Callable[[], bytes]) -> Classifier:
    """The model with this checksum, read and parsed once rather than for
    every repetition. What is fetched is checked against the checksum, so a
    model is never run from weights other than the registered ones."""
    model = _loaded.get(digest)
    if model is None:
        weights = fetch()
        if sha256(weights) != digest:
            raise ModelFormatError("The stored weights do not match their checksum.")
        model = load(weights)
        if len(_loaded) >= 8:
            _loaded.pop(next(iter(_loaded)))
        _loaded[digest] = model
    return model
