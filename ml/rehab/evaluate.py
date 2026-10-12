"""Scoring a model against the held-out test subjects (user story 4.3).

A candidate may replace the model in production only if it does at least as
well on the same held-out repetitions. This writes that evidence, as a file
an admin adds in the app (Admin > Scoring models > Add evaluation):

    # an exported classifier, run the way the API runs it
    python -m rehab.evaluate --data data/reps.npz --model models/<version>

    # the app's hand-written rule, on the very same repetitions
    python -m rehab.evaluate --data data/reps.npz --rule --segmentation data/Segmentation.csv \
        --landmarks data/landmarks

Both name the set they were scored on (the dataset, its split and its build),
so the app compares like with like and refuses anything else.

The rule is given every repetition the way the app would measure it: each
check's worst value held for more than a single frame, depth as how far the
lowest point stayed short of the target, judged against the thresholds the
app ships with. It calls a repetition correct when no check reaches AMBER.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
from collections.abc import Sequence
from pathlib import Path

import numpy as np

from rehab._backend import BACKEND, classifier, depth_shortfall, scoring, severity
from rehab.dataset import CHANNELS, frame_vector
from rehab.metrics import evaluate
from rehab.segmentation import read_segmentation

TEST = "test"


def default_checks() -> dict[str, list[dict]]:
    """Exercise slug -> the checks and thresholds the app ships with."""
    path = BACKEND / "migrations" / "versions" / "0003_exercise_templates_and_plans.py"
    spec = importlib.util.spec_from_file_location("physioai_default_exercises", path)
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except ImportError as exc:
        raise SystemExit(
            f"reading the app's thresholds needs the backend's packages installed: {exc}"
        ) from exc
    return {exercise["slug"]: exercise["checks"] for exercise in module.DEFAULT_EXERCISES}


def steady(series: np.ndarray) -> np.ndarray:
    """What a check held for more than one frame: the middle of its last
    three measured values (the value itself for the first two), as the app
    does, so one wild frame is not the "worst" of a repetition."""
    out = np.empty_like(series)
    for i in range(len(series)):
        out[i] = series[i] if i < 2 else np.median(series[i - 2 : i + 1])
    return out


def rule_measures(series: np.ndarray, slug: str, checks: Sequence[dict]) -> dict[str, float | None]:
    """One repetition's frames (frames x channels, NaN where unmeasured) as
    the measures the app would send for it."""
    measures: dict[str, float | None] = {}
    for check in checks:
        column = series[:, CHANNELS.index(check["key"])]
        held = steady(column[np.isfinite(column)])
        if len(held) == 0:
            measures[check["key"]] = None
        elif check["key"] == "depth":
            measures[check["key"]] = depth_shortfall(slug, float(held.min()))
        else:
            measures[check["key"]] = float(held.max())
    return measures


def rule_predictions(data, segmentation: Path, landmarks_dir: Path) -> tuple[np.ndarray, int]:
    """The rule's verdict (1 correct, 0 incorrect) on every test repetition,
    and how many of them it could not measure at all."""
    repetitions = {rep.key: rep for rep in read_segmentation(segmentation)}
    checks = default_checks()
    test = np.flatnonzero(data["split"] == TEST)
    predicted = np.zeros(len(test), dtype=int)
    unmeasured = 0
    videos: dict[str, tuple[np.ndarray, float]] = {}
    for n, i in enumerate(test):
        rep = repetitions[str(data["key"][i])]
        name = f"{rep.video_id}_c{int(data['camera'][i])}"
        if name not in videos:
            loaded = np.load(Path(landmarks_dir) / f"{name}.npz")
            videos[name] = (loaded["landmarks"], float(loaded["aspect"]))
        landmarks, aspect = videos[name]
        frames = landmarks[rep.first_frame : min(rep.last_frame, len(landmarks) - 1) + 1]
        series = np.stack([frame_vector(pose, aspect=aspect, slug=rep.exercise) for pose in frames])
        measures = rule_measures(series, rep.exercise, checks[rep.exercise])
        if not scoring.is_scorable(measures):
            unmeasured += 1
        tier, _, _ = severity.classify(measures, checks[rep.exercise])
        predicted[n] = 1 if tier in (severity.OK, severity.INFO) else 0
    return predicted, unmeasured


def classifier_predictions(data, served: classifier.Classifier, names: Sequence[str]) -> np.ndarray:
    test = np.flatnonzero(data["split"] == TEST)
    probabilities = [
        served.probability_correct(data["x"][i], data["mask"][i], names[int(data["exercise"][i])])
        for i in test
    ]
    return np.array([1 if p >= scoring.CORRECT_FROM else 0 for p in probabilities])


def run(
    data_path: Path,
    model_dir: Path | None = None,
    *,
    segmentation: Path | None = None,
    landmarks: Path | None = None,
) -> dict:
    """The evaluation of one model on the dataset's test subjects, in the
    form the app's registry takes."""
    data = np.load(data_path)
    manifest = json.loads(data_path.with_suffix(".json").read_text())
    names = manifest["exercises"]
    test = data["split"] == TEST
    if not test.any():
        raise SystemExit("the dataset has no test repetitions")

    extra: dict = {}
    if model_dir is None:
        if segmentation is None or landmarks is None:
            raise SystemExit("--rule needs --segmentation and --landmarks")
        version = scoring.VERSION
        predicted, unmeasured = rule_predictions(data, segmentation, landmarks)
        extra["unmeasured_repetitions"] = unmeasured
    else:
        record = json.loads((model_dir / "record.json").read_text())
        if record["training_data"]["dataset_sha256"] != manifest["dataset_sha256"]:
            raise SystemExit("this is not the dataset the model was trained and tested on")
        served = classifier.load((model_dir / "serving.npz").read_bytes())
        version = record["model_version"]
        predicted = classifier_predictions(data, served, names)

    metrics = evaluate(data["label"][test], predicted, data["exercise"][test], names)
    return {
        "model_version": version,
        "eval_set": classifier.eval_set_name(manifest),
        "metrics": {**metrics, **extra},
    }


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--data", type=Path, required=True)
    which = parser.add_mutually_exclusive_group(required=True)
    which.add_argument("--model", type=Path, help="models/<version>, after rehab.export")
    which.add_argument("--rule", action="store_true", help="evaluate the app's rule instead")
    parser.add_argument("--segmentation", type=Path)
    parser.add_argument("--landmarks", type=Path)
    parser.add_argument("--out", type=Path, help="default: evaluations/<version>.json")
    args = parser.parse_args(argv)
    result = run(args.data, args.model, segmentation=args.segmentation, landmarks=args.landmarks)
    out = args.out or Path("evaluations") / f"{result['model_version']}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2) + "\n")
    m = result["metrics"]
    print(f"{result['model_version']} on {result['eval_set']}")
    print(
        f"agreement {m['agreement']:.1%}, balanced {m['balanced_accuracy']:.1%} over {m['repetitions']} "
        f"repetitions (always-'correct' baseline {m['majority_baseline_agreement']:.1%})"
    )
    print(f"written to {out}")


if __name__ == "__main__":
    main()
