"""Deriving the feedback thresholds from REHAB24-6's expert labels (story 3.4).

The thresholds the app shipped with were starting values chosen by hand. On
the test subjects they agree with the expert labels 51.4% of the time: they
call 177 of 220 correct repetitions incorrect. This module sets them from
the labelled data instead, using only the eight non-test subjects, and then
scores the result once on the test subjects.

Every level is learned from the labelled repetitions, filmed from the side
the app films each exercise from (the exercise's camera view, migration 0015),
because that is how the app will measure them:

- AMBER: where a repetition stops counting as correct. Only for a check the
  data shows to tell incorrect from correct repetitions (a bootstrap 95%
  interval of its separation lies above chance) is it searched, one check at a
  time, for the best balanced accuracy against the expert labels (a
  repetition with no check at AMBER or above counts as correct). A check that
  shows no such signal from this camera view only warns beyond what correct
  repetitions do: AMBER just above their 98th percentile.
- INFO, a minor refinement: where a quarter of the correct repetitions
  still reach it (their 75th percentile), below AMBER.
- RED, the safety pause: beyond what correct repetitions do. The labels say
  only correct or incorrect, never "dangerous", so RED is placed where only
  2% of the correct repetitions reach (their 98th percentile), above AMBER:
  a value the expert practically never accepted as correct. Only a check the
  data shows to carry signal can pause a session: one without signal has no
  RED, since nothing in the data links it to incorrect form (from the side,
  "knee alignment" measures knee bend, so it would pause every deep lunge). A check the
  template never lets pause a session (RED empty: elbow straightness, leg
  straightness, depth, the lunge's back posture) stays that way; whether a
  check can pause is a design decision the labels cannot make.

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

# Which way the app films each exercise (migration 0015). Thresholds are
# learned from the repetitions filmed this way, since that is what the app sees.
APP_VIEW = {
    "arm-abduction": "front",
    "leg-abduction": "front",
    "leg-lunge": "side",
    "push-ups": "side",
    "squats": "front",
}
INFO_QUANTILE = 0.75  # of correct repetitions
RED_QUANTILE = 0.98  # of correct repetitions
BOOTSTRAP = 1000  # resamples for a check's separation interval


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


def _auc(values: np.ndarray, labels: np.ndarray) -> float | None:
    """Chance that an incorrect repetition measures higher than a correct one."""
    bad, good = values[labels == 0], values[labels == 1]
    if len(bad) == 0 or len(good) == 0:
        return None
    higher = (bad[:, None] > good[None, :]).mean() + 0.5 * (bad[:, None] == good[None, :]).mean()
    return round(float(higher), 3)


def separates(values: np.ndarray, labels: np.ndarray, seed: int = 2026) -> tuple[bool, list[float] | None]:
    """Whether incorrect repetitions measure higher than correct ones beyond
    chance: the bootstrap 95% interval of the separation (AUC) lies above 0.5.
    Also the interval."""
    finite = np.isfinite(values)
    v, lab = values[finite], labels[finite]
    if (lab == 0).sum() < 2 or (lab == 1).sum() < 2:
        return False, None
    rng = np.random.default_rng(seed)
    aucs = []
    for _ in range(BOOTSTRAP):
        pick = rng.integers(0, len(v), len(v))
        a = _auc(v[pick], lab[pick])
        if a is not None:
            aucs.append(a)
    low, high = np.quantile(aucs, [0.025, 0.975])
    return bool(low > 0.5), [round(float(low), 3), round(float(high), 3)]


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
    signal = {k: separates(values[k], labels) for k in keys}
    correct_values = {k: values[k][np.isfinite(values[k]) & (labels == 1)] for k in keys}

    def predict(ambers: dict) -> np.ndarray:
        bad = np.zeros(len(labels), dtype=bool)
        for k in keys:
            v = values[k]
            bad |= np.isfinite(v) & (v >= ambers[k])
        return (~bad).astype(int)

    before = _balanced(labels, predict(amber))
    # Without signal, a check only warns beyond what correct repetitions do.
    for k in keys:
        if not signal[k][0] and len(correct_values[k]):
            amber[k] = _round(float(np.quantile(correct_values[k], RED_QUANTILE))) + STEP
    for _ in range(ROUNDS):
        changed = False
        for k in keys:
            if not signal[k][0]:
                continue
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
        info = (
            _round(float(np.quantile(finite_correct, INFO_QUANTILE)))
            if len(finite_correct)
            else float(c["info"])
        )
        info = max(0.0, min(info, a - STEP))
        red = c.get("red")
        if not signal[k][0]:
            red = None
        elif red is not None and len(finite_correct):
            red = max(_round(float(np.quantile(finite_correct, RED_QUANTILE))), a + STEP)
        new_checks.append({**c, "info": info, "amber": a, "red": red})
    finite_rows = {k: np.isfinite(values[k]) for k in keys}
    report = {
        "examples": int(len(labels)),
        # How well each check alone tells incorrect from correct (0.5: not at
        # all; 1: perfectly), on the repetitions where it was measured.
        "separation_auc": {k: _auc(values[k][finite_rows[k]], labels[finite_rows[k]]) for k in keys},
        "separation_interval": {k: signal[k][1] for k in keys},
        "signal": {k: signal[k][0] for k in keys},
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
    # Only repetitions filmed the way the app films the exercise count: the
    # others are what the app never sees.
    viewed = [
        m if APP_VIEW.get(s) == v else dict.fromkeys(m)
        for m, s, v in zip(measures, slugs, views, strict=True)
    ]
    app_view = np.array([APP_VIEW.get(s) == v for s, v in zip(slugs, views, strict=True)])

    new = copy.deepcopy(old)
    per_exercise = {}
    fit_rows = (split != TEST) & app_view
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

    fit_sel, test_sel = np.flatnonzero(fit_rows), np.flatnonzero((split == TEST) & app_view)
    report = {
        "created_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "dataset_sha256": manifest.get("dataset_sha256"),
        "derived_from_subjects": sorted({int(p) for p in person[fit_rows]}),
        "tested_on_subjects": sorted({int(p) for p in person[split == TEST]}),
        "rule": "a repetition is called correct when no check reaches AMBER",
        "views": "learned and tested on the repetitions filmed from the exercise's camera view (APP_VIEW)",
        "levels": {
            "amber": "best balanced accuracy against the labels",
            "info": f"{INFO_QUANTILE:.0%} quantile of correct repetitions",
            "red": f"{RED_QUANTILE:.0%} quantile of correct repetitions; empty stays empty",
        },
        "non_test": {"old": judged(old, fit_sel), "new": judged(new, fit_sel)},
        "test": {"old": judged(old, test_sel), "new": judged(new, test_sel)},
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
    for part in ("non_test", "test"):
        o, n = report[part]["old"], report[part]["new"]
        print(
            f"{part:9} old: agreement {_pct(o['agreement'])}, balanced {_pct(o['balanced_accuracy'])}"
            f"   new: agreement {_pct(n['agreement'])}, balanced {_pct(n['balanced_accuracy'])}"
        )
    for slug, r in report["per_exercise"].items():
        for key, change in r["changes"].items():
            print(
                f"  {slug:14} {key:13} info {change['info']}  amber {change['amber']}  red {change['red']}"
                f"  separation {r['separation_auc'][key]} {r['separation_interval'][key]}"
                f"{'' if r['signal'][key] else '  (no signal: warns beyond correct)'}"
            )
    print(f"written to {out}")


if __name__ == "__main__":
    main()
