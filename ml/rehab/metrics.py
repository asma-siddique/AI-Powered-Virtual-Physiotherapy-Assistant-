"""How well predictions agree with REHAB24-6's correctness labels."""

from __future__ import annotations

from collections.abc import Sequence

import numpy as np

# User story 4.1 / NFR: at least 85% agreement with the expert labels.
TARGET_AGREEMENT = 0.85


def evaluate(labels: np.ndarray, predicted: np.ndarray, exercises: np.ndarray, names: Sequence[str]) -> dict:
    """Agreement overall and per exercise, balanced accuracy (the mean of the
    accuracy on correct and on incorrect repetitions, so a model that always
    says "correct" cannot look good), and the confusion counts."""
    labels = np.asarray(labels).astype(int)
    predicted = np.asarray(predicted).astype(int)
    exercises = np.asarray(exercises).astype(int)

    def summary(sel: np.ndarray) -> dict:
        y, p = labels[sel], predicted[sel]
        if len(y) == 0:
            return {"repetitions": 0}
        recalls = [float((p[y == c] == c).mean()) for c in (0, 1) if (y == c).any()]
        return {
            "repetitions": int(len(y)),
            "agreement": float((y == p).mean()),
            "balanced_accuracy": float(np.mean(recalls)),
            "confusion": {
                "correct_called_correct": int(((y == 1) & (p == 1)).sum()),
                "correct_called_incorrect": int(((y == 1) & (p == 0)).sum()),
                "incorrect_called_correct": int(((y == 0) & (p == 1)).sum()),
                "incorrect_called_incorrect": int(((y == 0) & (p == 0)).sum()),
            },
        }

    result = summary(np.ones_like(labels, dtype=bool))
    result["by_exercise"] = {name: summary(exercises == i) for i, name in enumerate(names)}
    # What always answering the most common label would score, for comparison.
    majority = int(round(labels.mean())) if len(labels) else 1
    result["majority_baseline_agreement"] = float((labels == majority).mean()) if len(labels) else 0.0
    result["meets_target"] = bool(result.get("agreement", 0.0) >= TARGET_AGREEMENT)
    return result
