"""Deriving the feedback thresholds from REHAB24-6's expert labels (story 3.4).

The thresholds the app shipped with were starting values chosen by hand. On
the test subjects they agree with the expert labels 51.4% of the time: they
call 177 of 220 correct repetitions incorrect. This module sets them from
the labelled data instead, using only the eight non-test subjects, and then
scores the result once on the test subjects.

What the labels can and cannot say: a repetition is labelled only correct or
incorrect. So the data decides where AMBER starts (a repetition with no check
at AMBER or above counts as correct). It cannot say what is dangerous, so
RED is left as it was, except that it is moved up if AMBER would otherwise
reach it. INFO, a minor refinement, is placed where a quarter of correct
repetitions still reach it.

    python -m rehab.thresholds --data data/reps.npz --segmentation data/Segmentation.csv \\
        --landmarks data/landmarks

writes evaluations/thresholds-<date>.json: the old and new thresholds of
every check, how often each set agrees with the labels on the non-test
subjects, and the new set's one evaluation on the test subjects.
"""

from __future__ import annotations

import argparse
import copy
import json
import math
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path

import numpy as np

from rehab.evaluate import TEST, all_measures, default_checks, rule_verdicts
from rehab.metrics import evaluate
from rehab.segmentation import read_segmentation

STEP = 0.5  # thresholds are rounded to half a degree

# The view in which each check measures what it says. Seen from the side,
# "knee valgus" measures knee bend (about 90 degrees in a squat) and
# "sideways lean" measures forward lean; seen from the front, a forward lean
# or a hip sag is invisible. A check's thresholds are derived only from the
# repetitions filmed in its view.
CHECK_VIEW = {
    "elbow_bend": "front",
    "knee_bend": "front",
    "knee_valgus": "front",
    "knee_forward": "side",
    "hip_sag": "side",
    "depth": "side",
}
# trunk_lean is a sideways lean for the two abductions, a forward lean otherwise.
TRUNK_LEAN_VIEW = {"arm-abduction": "front", "leg-abduction": "front"}


def check_view(key: str, slug: str) -> str:
    if key == "trunk_lean":
        return TRUNK_LEAN_VIEW.get(slug, "side")
    return CHECK_VIEW[key]


def view_of(camera: int, orientation: str) -> str:
    """REHAB24-6 records which way the person faces camera 17; camera 18
    stands at a right angle to it."""
    if orientation == "half-profile":
        return "oblique"
    facing_17 = orientation == "front"
    return "front" if (camera == 17) == facing_17 else "side"


def in_view(measures: dict, slug: str, view: str) -> dict:
    """The measures, with every check that is not valid in this view left
    out (treated as not measured)."""
    return {k: (v if check_view(k, slug) == view else None) for k, v in measures.items()}


ROUNDS = 6  # passes of coordinate search per exercise


def _balanced(labels: np.ndarray, predicted: np.ndarray) -> float:
    recalls = [float((predicted[labels == c] == c).mean()) for c in (0, 1) if (labels == c).any()]
    return float(np.mean(recalls)) if recalls else 0.0


def _round(value: float) -> float:
    return round(value / STEP) * STEP


def derive_exercise(
    measures: Sequence[dict], labels: np.ndarray, checks: list[dict]
) -> tuple[list[dict], dict]:
    """New thresholds for one exercise's checks, from its non-test
    repetitions. AMBER is searched one check at a time, keeping the others
    fixed, to maximise balanced accuracy, until nothing changes."""
    keys = [c["key"] for c in checks]
    values = {
        k: np.array([np.nan if m.get(k) is None else m[k] for m in measures], dtype=float) for k in keys
    }
    amber = {c["key"]: float(c["amber"]) for c in checks}

    def predict(ambers: dict) -> np.ndarray:
        bad = np.zeros(len(labels), dtype=bool)
        for k in keys:
            v = values[k]
            bad |= np.isfinite(v) & (v >= ambers[k])
        return (~bad).astype(int)

    before = _balanced(labels, predict(amber))
    for _ in range(ROUNDS):
        changed = False
        for k in keys:
            finite = values[k][np.isfinite(values[k])]
            if len(finite) == 0:
                continue
            candidates = {_round(q) for q in np.quantile(finite, np.linspace(0.02, 0.98, 49))}
            candidates.add(amber[k])
            best_value, best_score = amber[k], _balanced(labels, predict(amber))
            for value in sorted(candidates):
                if value <= 0:
                    continue
                trial = {**amber, k: value}
                score = _balanced(labels, predict(trial))
                if score > best_score + 1e-9:
                    best_value, best_score = value, score
            if best_value != amber[k]:
                amber[k], changed = best_value, True
        if not changed:
            break

    new_checks = []
    for c in checks:
        k = c["key"]
        finite_correct = values[k][np.isfinite(values[k]) & (labels == 1)]
        a = amber[k]
        info = _round(float(np.quantile(finite_correct, 0.75))) if len(finite_correct) else float(c["info"])
        info = max(0.0, min(info, a - STEP))
        red = c.get("red")
        if red is not None and red <= a:
            # The data moved AMBER past RED: RED keeps its old distance above AMBER.
            red = a + (float(c["red"]) - float(c["amber"]))
        new_checks.append({**c, "info": info, "amber": a, "red": red})
    report = {
        "examples": int(len(labels)),
        "balanced_accuracy_before": before,
        "balanced_accuracy_after": _balanced(labels, predict(amber)),
        "changes": {
            c["key"]: {
                "info": [c["info"], n["info"]],
                "amber": [c["amber"], n["amber"]],
                "red": [c.get("red"), n["red"]],
            }
            for c, n in zip(checks, new_checks, strict=True)
        },
    }
    return new_checks, report


def run(data_path: Path, segmentation: Path, landmarks: Path) -> dict:
    data = np.load(data_path)
    manifest = json.loads(data_path.with_suffix(".json").read_text())
    split, labels, person = data["split"], data["label"], data["person"]
    old = default_checks()
    rows = np.arange(len(labels))
    print(f"measuring {len(rows)} repetitions the way the app does ...", flush=True)
    measures, slugs = all_measures(data, rows, segmentation, landmarks, old)
    slugs_arr = np.array(slugs)
    orientation = {f"{r.video_id}#{r.repetition}": r.orientation for r in read_segmentation(segmentation)}
    views = [view_of(int(data["camera"][i]), orientation[str(data["key"][i])]) for i in rows]
    # What each repetition says about form when every check is read only in
    # its own view: the patient standing as each check needs.
    viewed = [in_view(m, s, v) for m, s, v in zip(measures, slugs, views, strict=True)]

    new = copy.deepcopy(old)
    per_exercise = {}
    fit_rows = split != TEST
    for slug in sorted(set(slugs)):
        sel = np.flatnonzero(fit_rows & (slugs_arr == slug))
        new[slug], per_exercise[slug] = derive_exercise([viewed[i] for i in sel], labels[sel], old[slug])

    def judged(checks: dict, sel: np.ndarray, source=None) -> dict:
        source = measures if source is None else source
        predicted, unmeasured = rule_verdicts([source[i] for i in sel], list(slugs_arr[sel]), checks)
        names = manifest["exercises"]
        m = evaluate(labels[sel], predicted, data["exercise"][sel], names)
        m["unmeasured_repetitions"] = unmeasured
        return m

    fit_sel, test_sel = np.flatnonzero(fit_rows), np.flatnonzero(~fit_rows)
    report = {
        "created_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "dataset_sha256": manifest.get("dataset_sha256"),
        "derived_from_subjects": sorted({int(p) for p in person[fit_rows]}),
        "tested_on_subjects": sorted({int(p) for p in person[~fit_rows]}),
        "rule": "a repetition is called correct when no check reaches AMBER",
        "views": "each check derived from the repetitions filmed in its own view (CHECK_VIEW)",
        "non_test": {"old": judged(old, fit_sel, viewed), "new": judged(new, fit_sel, viewed)},
        # Each check read only in its own view: the patient positioned as each check needs.
        "test": {"old": judged(old, test_sel, viewed), "new": judged(new, test_sel, viewed)},
        # Every check read in every view, as the app does today: it cannot tell the view.
        "test_all_views": {"old": judged(old, test_sel), "new": judged(new, test_sel)},
        "per_exercise": per_exercise,
        "checks": new,
    }
    return report


def _pct(x: float) -> str:
    return "n/a" if x is None or (isinstance(x, float) and math.isnan(x)) else f"{x:.1%}"


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--segmentation", type=Path, required=True)
    parser.add_argument("--landmarks", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args(argv)
    report = run(args.data, args.segmentation, args.landmarks)
    out = args.out or Path("evaluations") / f"thresholds-{datetime.now(UTC):%Y%m%d%H%M}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + "\n")
    for part in ("non_test", "test", "test_all_views"):
        o, n = report[part]["old"], report[part]["new"]
        print(
            f"{part:9} old: agreement {_pct(o['agreement'])}, balanced {_pct(o['balanced_accuracy'])}"
            f"   new: agreement {_pct(n['agreement'])}, balanced {_pct(n['balanced_accuracy'])}"
        )
    for slug, r in report["per_exercise"].items():
        for key, change in r["changes"].items():
            print(f"  {slug:14} {key:13} info {change['info']}  amber {change['amber']}  red {change['red']}")
    print(f"written to {out}")


if __name__ == "__main__":
    main()
