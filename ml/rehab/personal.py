"""The personal reference ("personal-2"): judging a repetition by how far it
is from the same person's own correct repetitions.

In REHAB24-6 the physiotherapist suggested a different mistake to each
person, so a classifier that judges people it has never seen learns one
person's mistakes and misses the next one's. Comparing each repetition with
that person's own first correct repetitions does not have that problem.

For every recording, only repetitions filmed from the side the app asks for
(the exercise's camera view, migration 0015) are used. The reference is the
mean of its first REFERENCE_REPETITIONS correct repetitions. Every other
repetition of the recording is judged by its distance from it, measured by
the very function the API uses (app.personal.distance):

- over the exercise's own channels: its target joints on both sides and its
  checks (TARGETS, the shipped templates; a test holds them equal);
- each channel's difference divided by its spread, learned from the data:
  the median difference of correct repetitions from their own reference;
- a repetition is correct up to its exercise's cut, the one with the best
  balanced accuracy.

    python -m rehab.personal --data data/reps.npz --segmentation data/Segmentation.csv \\
        --model models/rehab-cnn-202611121625-ae9b9741 --ship ../backend/app/personal_model.json

1. Cross-validation over the 8 non-test subjects, in the folds of
   rehab.crossval: each fold's spreads and cuts are learned on the other folds.
2. Spreads and cuts learned on all 8 non-test subjects (what the API ships),
   scored once on the 2 test subjects, beside the production classifier on
   exactly the same repetitions when --model is given.

writes evaluations/personal-2.json and, with --ship, the model the API loads.
"""

from __future__ import annotations

import argparse
import json
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path

import numpy as np

from rehab._backend import classifier, personal, scoring
from rehab.crossval import subject_folds
from rehab.metrics import evaluate
from rehab.segmentation import read_segmentation
from rehab.thresholds import view_of

# Which way each shipped exercise is filmed (migration 0015; tests hold the two equal).
APP_VIEW = {
    "arm-abduction": "front",
    "leg-abduction": "front",
    "leg-lunge": "side",
    "push-ups": "side",
    "squats": "front",
}
# Each shipped exercise's target joints and checks (migration 0003; tests hold them equal).
TARGETS = {
    "arm-abduction": (("shoulder", "elbow", "hip"), ("trunk_lean", "elbow_bend")),
    "leg-abduction": (("hip", "knee", "ankle"), ("trunk_lean", "knee_bend")),
    "leg-lunge": (("hip", "knee", "ankle"), ("knee_valgus", "knee_forward", "trunk_lean")),
    "push-ups": (("shoulder", "elbow", "hip", "knee", "ankle"), ("hip_sag", "depth")),
    "squats": (("hip", "knee", "ankle"), ("knee_valgus", "trunk_lean", "depth")),
}
TEST = "test"


def own_channels(slug: str) -> list[str]:
    joints, checks = TARGETS[slug]
    return [f"{side}_{joint}" for joint in joints for side in ("left", "right")] + list(checks)


class Pairs:
    """Every judged repetition with its recording's reference, app view only."""

    def __init__(self, data, names: Sequence[str], segmentation: Path, k: int) -> None:
        orientation = {f"{r.video_id}#{r.repetition}": r.orientation for r in read_segmentation(segmentation)}
        keys = [str(key) for key in data["key"]]
        slugs = [names[int(e)] for e in data["exercise"]]
        in_view = np.array(
            [
                view_of(int(camera), orientation[key]) == APP_VIEW.get(s)
                for camera, key, s in zip(data["camera"], keys, slugs, strict=True)
            ]
        )
        recording = np.array(
            [f"{key.split('#')[0]}_c{camera}" for key, camera in zip(keys, data["camera"], strict=True)]
        )
        number = np.array([int(key.split("#")[1]) for key in keys])
        x, mask, label = data["x"], data["mask"], data["label"]
        self.rows, self.references = [], []
        for name in np.unique(recording[in_view]):
            rows = np.flatnonzero((recording == name) & in_view)
            rows = rows[np.argsort(number[rows])]
            reference_rows = [r for r in rows if label[r] == 1][:k]
            if len(reference_rows) < k:
                continue
            reference = personal.reference_of([(x[r], mask[r]) for r in reference_rows])
            for r in rows:
                if r not in reference_rows:
                    self.rows.append(int(r))
                    self.references.append(reference)
        self.rows = np.array(self.rows, dtype=int)
        self.x, self.mask = x, mask
        self.label = label[self.rows]
        self.exercise = data["exercise"][self.rows]
        self.person = data["person"][self.rows]
        self.split = data["split"][self.rows]
        self.slug = np.array([slugs[r] for r in self.rows])

    def spreads(self, slug: str, use: np.ndarray) -> dict[str, float]:
        """Each of the exercise's channels' spread, from the correct
        repetitions among the chosen ones."""
        out = {}
        for name in own_channels(slug):
            c = personal.CHANNELS.index(name)
            diffs: list[float] = []
            for i in np.flatnonzero(use & (self.slug == slug) & (self.label == 1)):
                r = self.rows[i]
                reference, reference_mask = self.references[i]
                both = (self.mask[r, c] > 0) & (reference_mask[c] > 0)
                diffs.extend((np.abs(self.x[r, c] - reference[c])[both] * classifier.ANGLE_SCALE).tolist())
            out[name] = round(personal.spread(diffs), 3)
        return out

    def distances(self, slug: str, spreads: dict[str, float]) -> np.ndarray:
        out = np.full(len(self.rows), np.nan)
        channels = [personal.CHANNELS.index(name) for name in spreads]
        for i in np.flatnonzero(self.slug == slug):
            r = self.rows[i]
            d = personal.distance(
                self.x[r], self.mask[r], *self.references[i], channels, list(spreads.values())
            )
            if d is not None:
                out[i] = d
        return out


def best_cut(distance: np.ndarray, label: np.ndarray) -> float:
    """The cut with the best balanced accuracy on these repetitions (the
    smallest of equal ones)."""

    def balanced(cut: float) -> float:
        said = (distance <= cut).astype(int)
        return float(np.mean([np.mean(said[label == c] == c) for c in (0, 1) if (label == c).any()]))

    return float(max(np.unique(distance), key=lambda c: (balanced(c), -c)))


def fit(pairs: Pairs, use: np.ndarray) -> dict[str, dict]:
    """Spreads and cut per exercise, learned on the chosen repetitions only."""
    model = {}
    for slug in TARGETS:
        rows = use & (pairs.slug == slug)
        if len(np.unique(pairs.label[rows])) < 2:
            continue
        spreads = pairs.spreads(slug, use)
        d = pairs.distances(slug, spreads)
        ok = rows & ~np.isnan(d)
        model[slug] = {"cut": round(best_cut(d[ok], pairs.label[ok]), 4), "spreads": spreads}
    return model


def judge(pairs: Pairs, model: dict[str, dict], rows: np.ndarray) -> np.ndarray:
    """1 correct, 0 incorrect, -1 not judged, for the chosen rows."""
    said = np.full(len(pairs.rows), -1)
    for slug, entry in model.items():
        d = pairs.distances(slug, entry["spreads"])
        sel = rows & (pairs.slug == slug) & ~np.isnan(d)
        said[sel] = (d[sel] <= entry["cut"]).astype(int)
    return said


def run(
    data_path: Path,
    segmentation: Path,
    model_dir: Path | None = None,
    k: int = personal.REFERENCE_REPETITIONS,
) -> dict:
    data = np.load(data_path)
    manifest = json.loads(data_path.with_suffix(".json").read_text())
    names = manifest["exercises"]
    if tuple(manifest["channels"]) != personal.CHANNELS:
        raise SystemExit("the dataset's channels are not the ones the API keeps (app.personal.CHANNELS)")
    pairs = Pairs(data, names, segmentation, k)
    non_test = pairs.split != TEST

    # 1. Cross-validation: no fold's spreads or cuts are learned on its own subjects.
    folds = subject_folds(data["person"], data["split"])
    said_cv = np.full(len(pairs.rows), -1)
    for group in folds:
        held = non_test & np.isin(pairs.person, group)
        said = judge(pairs, fit(pairs, non_test & ~held), held)
        said_cv[held] = said[held]
    cv_rows = said_cv >= 0
    cross_validation = evaluate(pairs.label[cv_rows], said_cv[cv_rows], pairs.exercise[cv_rows], names)

    # 2. Learned on all 8 non-test subjects, scored once on the test subjects.
    model = fit(pairs, non_test)
    said_test = judge(pairs, model, ~non_test)
    keep = said_test >= 0
    test = evaluate(pairs.label[keep], said_test[keep], pairs.exercise[keep], names)
    report = {
        "created_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "dataset_sha256": manifest.get("dataset_sha256"),
        "splits_sha256": manifest["splits_sha256"],
        "reference_repetitions": k,
        "views": APP_VIEW,
        "model": {"version": personal.VERSION, "exercises": model},
        "cross_validation": {"folds": folds, **cross_validation},
        "test": test,
        "test_always_correct_agreement": float(pairs.label[keep].mean()),
    }
    if model_dir is not None:
        # The classifier on exactly the same test repetitions, for comparison.
        served = classifier.load((model_dir / "serving.npz").read_bytes())
        rows = pairs.rows[keep]
        said_model = np.array(
            [
                int(
                    served.probability_correct(data["x"][r], data["mask"][r], names[int(data["exercise"][r])])
                    >= scoring.CORRECT_FROM
                )
                for r in rows
            ]
        )
        report["classifier_on_the_same_repetitions"] = {
            "model_version": json.loads((model_dir / "record.json").read_text())["model_version"],
            **evaluate(pairs.label[keep], said_model, pairs.exercise[keep], names),
        }
    return report


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--segmentation", type=Path, required=True)
    parser.add_argument("--model", type=Path, help="models/<version>, to compare on the same repetitions")
    parser.add_argument("--references", type=int, default=personal.REFERENCE_REPETITIONS)
    parser.add_argument("--out", type=Path, default=Path("evaluations") / f"{personal.VERSION}.json")
    parser.add_argument("--ship", type=Path, help="also write the model the API loads here")
    args = parser.parse_args(argv)
    report = run(args.data, args.segmentation, args.model, args.references)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    if args.ship is not None:
        args.ship.write_text(json.dumps(report["model"], indent=2) + "\n")
    for name in ("cross_validation", "test"):
        m = report[name]
        print(
            f"{name} ({m['repetitions']} reps): agreement {m['agreement']:.1%}, "
            f"balanced {m['balanced_accuracy']:.1%}",
            {k: round(v["agreement"], 3) for k, v in m["by_exercise"].items()},
        )
    if "classifier_on_the_same_repetitions" in report:
        c = report["classifier_on_the_same_repetitions"]
        print(f"classifier on the same test reps: agreement {c['agreement']:.1%}")
    print("cuts:", {k: v["cut"] for k, v in report["model"]["exercises"].items()}, "written to", args.out)


if __name__ == "__main__":
    main()
