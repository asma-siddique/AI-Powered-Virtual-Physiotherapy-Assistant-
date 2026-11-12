"""Choosing how to train the classifier without touching the test subjects.

The first model picked its best epoch on two validation subjects and scored
75.3% on them but 60.7% on the test subjects: two people are too few to
choose with. Here every candidate setting is trained four times, each time
holding out a different group of the eight non-test subjects, and is judged
on all the held-out predictions pooled together. The test subjects are not
read at all.

    python -m rehab.crossval --data data/reps.npz

writes evaluations/crossval-<date>.json: for each candidate, the pooled
agreement and balanced accuracy after every epoch, and the best epoch. The
winner is then trained once on all eight subjects with
`python -m rehab.train --data data/reps.npz --out models --from-crossval evaluations/crossval-<date>.json`
and only then scored on the test subjects.
"""

from __future__ import annotations

import argparse
import json
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path

import numpy as np

from rehab.metrics import evaluate
from rehab.train import SETTINGS, fit, tensors_of

FOLDS = 4
MAX_EPOCHS = 60

# Candidate settings, each a change from rehab.train.SETTINGS.
CANDIDATES: dict[str, dict] = {
    "baseline": {},
    "mirror": {"mirror": True},
    "mirror+jitter": {"mirror": True, "shift": 2, "noise": 0.01},
    "small": {"hidden": 32, "dropout": 0.5, "weight_decay": 1e-3},
    "small+mirror+jitter": {
        "hidden": 32,
        "dropout": 0.5,
        "weight_decay": 1e-3,
        "mirror": True,
        "shift": 2,
        "noise": 0.01,
    },
    "regularised+mirror+jitter": {
        "dropout": 0.5,
        "weight_decay": 1e-3,
        "mirror": True,
        "shift": 2,
        "noise": 0.01,
    },
}


def subject_folds(person: np.ndarray, split: np.ndarray, folds: int = FOLDS) -> list[list[int]]:
    """The non-test subjects in `folds` groups of about the same number of
    examples: largest first, each into the group with the fewest so far."""
    pool = person[split != "test"]
    sizes = {int(p): int((pool == p).sum()) for p in np.unique(pool)}
    groups: list[list[int]] = [[] for _ in range(folds)]
    totals = [0] * folds
    for p in sorted(sizes, key=lambda q: (-sizes[q], q)):
        i = totals.index(min(totals))
        groups[i].append(p)
        totals[i] += sizes[p]
    return [sorted(g) for g in groups]


def run(data_path: Path, candidates: dict[str, dict] | None = None, max_epochs: int = MAX_EPOCHS) -> dict:
    data = np.load(data_path)
    manifest = json.loads(data_path.with_suffix(".json").read_text())
    names, channel_names = manifest["exercises"], manifest["channels"]
    split, person = data["split"], data["person"]
    groups = subject_folds(person, split)
    channels = data["x"].shape[1]
    labels = data["label"]

    results = {}
    for name, change in (candidates or CANDIDATES).items():
        settings = {**SETTINGS, **change, "epochs": max_epochs}
        # probabilities[epoch] = predictions for every non-test example
        held = np.flatnonzero(split != "test")
        probabilities = np.zeros((max_epochs, len(labels)), dtype=np.float32)
        for group in groups:
            held_out = np.isin(person, group) & (split != "test")
            training = (split != "test") & ~held_out
            train_tensors, _ = tensors_of(
                data, training, names, mirror=settings["mirror"], channels=channel_names
            )
            out_tensors, _ = tensors_of(data, held_out, names)
            rows = np.flatnonzero(held_out)

            def record(
                epoch, predict, model, rows=rows, out_tensors=out_tensors, probabilities=probabilities
            ):
                probabilities[epoch, rows] = predict(*out_tensors[:3])

            fit(train_tensors, settings, channels, len(names), record)
        curve = []
        for epoch in range(max_epochs):
            m = evaluate(
                labels[held], (probabilities[epoch, held] >= 0.5).astype(int), data["exercise"][held], names
            )
            curve.append(
                {"epoch": epoch, "agreement": m["agreement"], "balanced_accuracy": m["balanced_accuracy"]}
            )
        best = max(curve, key=lambda c: (c["balanced_accuracy"], -c["epoch"]))
        results[name] = {"settings": change, "best": best, "curve": curve}
        print(
            f"{name:28} best epoch {best['epoch']:2}: agreement {best['agreement']:.1%}, "
            f"balanced {best['balanced_accuracy']:.1%}",
            flush=True,
        )

    winner = max(results, key=lambda n: results[n]["best"]["balanced_accuracy"])
    return {
        "created_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "dataset_sha256": manifest.get("dataset_sha256"),
        "splits_sha256": manifest["splits_sha256"],
        "folds": groups,
        "judged_on": "pooled predictions for the held-out subjects of every fold; test subjects never read",
        "majority_baseline_agreement": float(
            max(labels[split != "test"].mean(), 1 - labels[split != "test"].mean())
        ),
        "candidates": results,
        "winner": {"name": winner, "settings": results[winner]["settings"], **results[winner]["best"]},
    }


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--epochs", type=int, default=MAX_EPOCHS)
    args = parser.parse_args(argv)
    report = run(args.data, max_epochs=args.epochs)
    out = args.out or Path("evaluations") / f"crossval-{datetime.now(UTC):%Y%m%d%H%M}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + "\n")
    w = report["winner"]
    print(
        f"winner: {w['name']} at epoch {w['epoch']} ({w['balanced_accuracy']:.1%} balanced); written to {out}"
    )


if __name__ == "__main__":
    main()
