"""Judging a repetition against the patient's own reference ("personal-2").

In REHAB24-6 the physiotherapist suggested a different mistake to each
person, so "incorrect" means something different for every patient. A model
that has to judge people it has never seen does little better than chance on
some exercises (ml/README.md). What does work is comparing each repetition
with that patient's own correct ones: a physiotherapist picks two repetitions
they saw done correctly, their joint angles are averaged into the patient's
reference for that exercise, and later repetitions are judged by how far they
are from it.

The distance, after resampling to STEPS steps exactly as the classifier's
input is built (app.classifier.resample), is taken over the exercise's own
channels only (its target joints on both sides and its checks). On each
channel the difference in degrees is divided by that channel's spread: how
much a person's correct repetitions typically differ from their own
reference on it (the median, learned from the data, at least MIN_SPREAD). So
a joint that wobbles a lot counts for less than one that is normally steady.
The distance is the mean of those scaled differences over every channel and
step measured both in the repetition and in the reference, and a repetition
is correct up to its exercise's cut.

Channels, spreads and cuts were all learned on the 8 non-test subjects of
REHAB24-6 and scored once on the 2 test subjects (ml/rehab/personal.py). They
ship as personal_model.json, a copy of ml/evaluations/personal-2.json's model
(tests/test_personal.py holds the two equal).

Like the classifier, this only decides whether a repetition was done
correctly, and so the form score. The RED / AMBER / INFO tiers and the safety
pause stay with the thresholds.
"""

import json
from collections.abc import Sequence
from pathlib import Path

import numpy as np

from app.classifier import ANGLE_SCALE, resample

VERSION = "personal-2"

# The channels of every frame, in order: both sides of each joint angle, then
# each check. The same as the classifier's training data (ml/rehab/dataset.py).
JOINTS = ("shoulder", "elbow", "hip", "knee", "ankle")
CHECKS = ("trunk_lean", "elbow_bend", "knee_bend", "knee_valgus", "knee_forward", "hip_sag", "depth")
CHANNELS = tuple(f"{side}_{joint}" for joint in JOINTS for side in ("left", "right")) + CHECKS
STEPS = 32

# How many repetitions make a reference: two scored better than one or three
# in cross-validation (ml/README.md).
REFERENCE_REPETITIONS = 2

# A session keeps the series of its first this many repetitions, the ones a
# physiotherapist can make the reference from. Every repetition's series
# would not fit the 500 KB a session may take (US 8.2).
STORED_SERIES = 10

# The smallest spread a channel can have, in degrees: below it, measurement
# noise would count as a real difference.
MIN_SPREAD = 0.5

MODEL_FILE = Path(__file__).with_name("personal_model.json")
MODEL = json.loads(MODEL_FILE.read_text(encoding="utf-8"))
if MODEL["version"] != VERSION:
    raise RuntimeError(f"{MODEL_FILE.name} is for {MODEL['version']}, not {VERSION}")

# Per exercise: the cut, and each of its channels with its spread in degrees.
CUTS: dict[str, float] = {slug: float(entry["cut"]) for slug, entry in MODEL["exercises"].items()}


def series_of(frames: Sequence[Sequence[float | None]]) -> tuple[np.ndarray, np.ndarray]:
    """A repetition's frames (one value per channel, None where not measured)
    -> values and mask, each (channels x STEPS), values divided by 180."""
    series = np.array(
        [[np.nan if value is None else value for value in frame] for frame in frames], dtype=np.float32
    )
    return resample(series, STEPS)


def encode(values: np.ndarray, mask: np.ndarray) -> list[list[float | None]]:
    """For storing: one list per channel, in degrees to a tenth, None where
    not measured. A tenth of a degree is far below every spread."""
    return [
        [round(float(v) * ANGLE_SCALE, 1) if m > 0 else None for v, m in zip(row, row_mask, strict=True)]
        for row, row_mask in zip(values, mask, strict=True)
    ]


def decode(stored: Sequence[Sequence[float | None]]) -> tuple[np.ndarray, np.ndarray]:
    """What encode stored -> values (divided by 180) and mask."""
    mask = np.array([[v is not None for v in row] for row in stored], dtype=np.float32)
    values = np.array([[0.0 if v is None else v for v in row] for row in stored], dtype=np.float32)
    return values / ANGLE_SCALE, mask


def reference_of(repetitions: Sequence[tuple[np.ndarray, np.ndarray]]) -> tuple[np.ndarray, np.ndarray]:
    """The mean of the repetitions, kept only where every one was measured."""
    mask = np.all([m > 0 for _, m in repetitions], axis=0).astype(np.float32)
    values = np.mean([v for v, _ in repetitions], axis=0) * mask
    return values.astype(np.float32), mask


def spread(differences_degrees: Sequence[float]) -> float:
    """A channel's spread: the median difference of correct repetitions from
    their own reference, in degrees, at least MIN_SPREAD."""
    if len(differences_degrees) == 0:
        return 1.0
    return max(float(np.median(differences_degrees)), MIN_SPREAD)


def distance(
    values: np.ndarray,
    mask: np.ndarray,
    reference: np.ndarray,
    reference_mask: np.ndarray,
    channels: Sequence[int],
    spreads: Sequence[float],
) -> float | None:
    """Mean difference from the reference over the given channels, each in
    units of its spread, over what was measured in both. None when they have
    nothing in common."""
    idx = np.asarray(channels, dtype=int)
    both = (mask[idx] > 0) & (reference_mask[idx] > 0)
    if not both.any():
        return None
    scaled = np.abs(values[idx] - reference[idx]) * ANGLE_SCALE / np.asarray(spreads, dtype=float)[:, None]
    return float(scaled[both].mean())


def distance_for(
    exercise: str, values: np.ndarray, mask: np.ndarray, reference: np.ndarray, reference_mask: np.ndarray
) -> float | None:
    """The distance as the shipped model measures it for this exercise; None
    for an exercise it has no channels for."""
    entry = MODEL["exercises"].get(exercise)
    if entry is None:
        return None
    channels = [CHANNELS.index(name) for name in entry["spreads"]]
    return distance(values, mask, reference, reference_mask, channels, list(entry["spreads"].values()))


def probability_correct(distance_value: float, exercise: str) -> float | None:
    """The distance as a number from 0 to 1 that is at least 0.5 exactly when
    the repetition is within the exercise's cut, so the form score is built
    the same way as a classifier's (app.scoring.classifier_score). None for an
    exercise without a cut."""
    cut = CUTS.get(exercise)
    if cut is None:
        return None
    return cut / (cut + distance_value)
