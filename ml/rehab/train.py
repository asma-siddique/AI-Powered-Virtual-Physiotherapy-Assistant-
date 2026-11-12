"""Training the repetition correctness classifier (SCRUM-47) and recording it
as one traceable record (SCRUM-48, user story 4.1).

A small 1-D convolutional network reads a repetition's resampled joint angles
and checks (with the mask of what was actually measured) plus which exercise
it is, and says whether the repetition was done correctly. It is trained on
the train subjects, the epoch with the best balanced accuracy on the
validation subjects is kept, and it is scored once on the test subjects,
who were never used for any choice.

    python -m rehab.train --data data/reps.npz --out models

writes models/<version>/model.pt and models/<version>/record.json, and a
copy of the record to model_records/<version>.json, which is committed. The record
holds the model version, the exact data it was trained on (checksums of the
annotations, the splits, the landmarks and the dataset), the settings, and
the validation and test results, so every later prediction can be traced to
it. A model is never written without its held-out evaluation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
from collections.abc import Sequence
from datetime import UTC, datetime
from pathlib import Path

import numpy as np

from rehab.metrics import TARGET_AGREEMENT, evaluate

SETTINGS = {
    "epochs": 80,
    # Augmentation, off unless asked for (rehab.crossval chooses it):
    # mirror = every training repetition also seen with left and right swapped;
    # shift = up to this many time steps earlier or later; noise = standard
    # deviation added to measured values (in units of 180 degrees).
    "mirror": False,
    "shift": 0,
    "noise": 0.0,
    # True: train on the train AND validation subjects for exactly "epochs"
    # epochs, chosen beforehand by cross-validation, instead of picking the
    # best epoch on the validation subjects.
    "fit_on_validation": False,
    "batch_size": 32,
    "learning_rate": 1e-3,
    "weight_decay": 1e-4,
    "hidden": 64,
    "dropout": 0.3,
    "seed": 2026,
}


def _build_model(channels: int, exercises: int, hidden: int, dropout: float):
    import torch.nn as nn  # noqa: PLC0415

    class RepClassifier(nn.Module):
        """values + mask (2 x channels, steps) -> convolutions -> pooled over
        time -> joined with the exercise -> probability of "correct"."""

        def __init__(self) -> None:
            super().__init__()
            self.features = nn.Sequential(
                nn.Conv1d(2 * channels, hidden, kernel_size=5, padding=2),
                nn.BatchNorm1d(hidden),
                nn.ReLU(),
                nn.Conv1d(hidden, hidden, kernel_size=5, padding=2),
                nn.BatchNorm1d(hidden),
                nn.ReLU(),
            )
            self.head = nn.Sequential(
                nn.Linear(2 * hidden + exercises, hidden),
                nn.ReLU(),
                nn.Dropout(dropout),
                nn.Linear(hidden, 1),
            )

        def forward(self, x, mask, exercise_onehot):
            import torch  # noqa: PLC0415

            h = self.features(torch.cat([x, mask], dim=1))
            pooled = torch.cat([h.mean(dim=2), h.amax(dim=2)], dim=1)
            return self.head(torch.cat([pooled, exercise_onehot], dim=1)).squeeze(1)

    return RepClassifier()


def _git_commit() -> str | None:
    try:
        return subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
            cwd=Path(__file__).parent,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def mirror_pairs(channels: Sequence[str]) -> list[tuple[int, int]]:
    """Index pairs of the same joint on the left and right side."""
    return [
        (i, list(channels).index("right_" + name[5:]))
        for i, name in enumerate(channels)
        if name.startswith("left_")
    ]


def mirrored(
    x: np.ndarray, mask: np.ndarray, pairs: Sequence[tuple[int, int]]
) -> tuple[np.ndarray, np.ndarray]:
    """The same repetitions with left and right swapped: the person seen in a
    mirror. The form checks already take the worse side, so they stay."""
    x2, m2 = x.copy(), mask.copy()
    for a, b in pairs:
        x2[:, [a, b]] = x[:, [b, a]]
        m2[:, [a, b]] = mask[:, [b, a]]
    return x2, m2


def _jitter(x, mask, settings: dict, generator):
    """A random shift in time (edges repeated, never wrapped round) and a
    little noise on measured values."""
    import torch  # noqa: PLC0415

    shift = int(settings.get("shift", 0))
    if shift:
        s = int(torch.randint(-shift, shift + 1, (1,), generator=generator))
        if s > 0:
            x = torch.cat([x[:, :, :1].expand(-1, -1, s), x[:, :, :-s]], dim=2)
            mask = torch.cat([mask[:, :, :1].expand(-1, -1, s), mask[:, :, :-s]], dim=2)
        elif s < 0:
            x = torch.cat([x[:, :, -s:], x[:, :, -1:].expand(-1, -1, -s)], dim=2)
            mask = torch.cat([mask[:, :, -s:], mask[:, :, -1:].expand(-1, -1, -s)], dim=2)
    noise = float(settings.get("noise", 0.0))
    if noise:
        x = x + noise * torch.randn(x.shape, generator=generator) * mask
    return x, mask


def fit(train: tuple, settings: dict, channels: int, exercises: int, after_epoch=None):
    """Trains one network on train = (x, mask, exercise one-hot, label) and
    returns it. after_epoch(epoch, predict) is called after every epoch;
    predict(x, mask, onehot) gives the probability of "correct"."""
    import torch  # noqa: PLC0415

    torch.manual_seed(settings["seed"])
    np.random.seed(settings["seed"])
    train_x, train_m, train_e, train_y = train
    model = _build_model(channels, exercises, settings["hidden"], settings["dropout"])
    optimizer = torch.optim.Adam(
        model.parameters(), lr=settings["learning_rate"], weight_decay=settings["weight_decay"]
    )
    # The loss is weighted so the classes count equally, so the model cannot
    # do well by calling everything correct (or incorrect).
    positives = float(train_y.sum())
    pos_weight = torch.tensor((len(train_y) - positives) / max(positives, 1.0))
    loss_fn = torch.nn.BCEWithLogitsLoss(pos_weight=pos_weight)

    def predict(x, m, e) -> np.ndarray:
        model.eval()
        with torch.no_grad():
            return torch.sigmoid(model(x, m, e)).numpy()

    generator = torch.Generator().manual_seed(settings["seed"])
    for epoch in range(settings["epochs"]):
        model.train()
        order = torch.randperm(len(train_y), generator=generator)
        for start in range(0, len(order), settings["batch_size"]):
            idx = order[start : start + settings["batch_size"]]
            if len(idx) < 2:
                continue  # batch normalisation needs more than one example
            x, m = _jitter(train_x[idx], train_m[idx], settings, generator)
            optimizer.zero_grad()
            loss = loss_fn(model(x, m, train_e[idx]), train_y[idx])
            loss.backward()
            optimizer.step()
        if after_epoch is not None:
            after_epoch(epoch, predict, model)
    model.eval()
    return model, predict


def tensors_of(data, sel: np.ndarray, names: Sequence[str], *, mirror: bool = False, channels=None):
    """Torch tensors for the selected examples; with mirror, each one twice."""
    import torch  # noqa: PLC0415

    x, m = data["x"][sel], data["mask"][sel]
    exercise, label = data["exercise"][sel], data["label"][sel]
    if mirror:
        x2, m2 = mirrored(x, m, mirror_pairs(channels))
        x, m = np.concatenate([x, x2]), np.concatenate([m, m2])
        exercise, label = np.concatenate([exercise, exercise]), np.concatenate([label, label])
    onehot = np.eye(len(names), dtype=np.float32)[exercise]
    return (
        torch.from_numpy(np.ascontiguousarray(x)),
        torch.from_numpy(np.ascontiguousarray(m)),
        torch.from_numpy(onehot),
        torch.from_numpy(label.astype(np.float32)),
    ), exercise


def train(
    data_path: Path,
    out_dir: Path,
    settings: dict | None = None,
    records_dir: Path | None = None,
    cross_validation: dict | None = None,
) -> Path:
    import torch  # noqa: PLC0415

    settings = {**SETTINGS, **(settings or {})}
    data = np.load(data_path)
    manifest = json.loads(data_path.with_suffix(".json").read_text())
    names = manifest["exercises"]
    split = data["split"]
    channels = data["x"].shape[1]
    channel_names = manifest["channels"]

    def held_out(name: str):
        tensors, exercise = tensors_of(data, split == name, names)
        return tensors, exercise

    final = bool(settings["fit_on_validation"])
    training = np.isin(split, ["train", "val"]) if final else split == "train"
    train_tensors, _ = tensors_of(data, training, names, mirror=settings["mirror"], channels=channel_names)
    val, val_exercise = held_out("val")
    test, test_exercise = held_out("test")
    if min(len(train_tensors[3]), len(val[3]), len(test[3])) == 0:
        raise SystemExit("every split needs examples; check the dataset manifest")

    def judged(predict, tensors) -> np.ndarray:
        return (predict(*tensors[:3]) >= 0.5).astype(int)

    best = {"score": -1.0, "epoch": -1, "state": None}

    def keep_best(epoch, predict, model):
        if final:
            return
        score = evaluate(val[3].numpy(), judged(predict, val), val_exercise, names)["balanced_accuracy"]
        if score > best["score"]:
            best.update(
                score=score, epoch=epoch, state={k: v.detach().clone() for k, v in model.state_dict().items()}
            )

    model, predict = fit(train_tensors, settings, channels, len(names), keep_best)
    if not final:
        model.load_state_dict(best["state"])
    best_epoch = settings["epochs"] - 1 if final else best["epoch"]
    # With fit_on_validation the validation subjects were trained on, so their
    # score says nothing; the cross-validation estimate stands in for it.
    val_metrics = None if final else evaluate(val[3].numpy(), judged(predict, val), val_exercise, names)
    test_metrics = evaluate(test[3].numpy(), judged(predict, test), test_exercise, names)

    weights_path = out_dir / "_pending.pt"
    out_dir.mkdir(parents=True, exist_ok=True)
    torch.save(model.state_dict(), weights_path)
    weights_sha = hashlib.sha256(weights_path.read_bytes()).hexdigest()
    created = datetime.now(UTC)
    version = f"rehab-cnn-{created:%Y%m%d%H%M}-{weights_sha[:8]}"
    target = out_dir / version
    target.mkdir(parents=True, exist_ok=False)
    weights_path.replace(target / "model.pt")

    record = {
        "model_version": version,
        "created_at": created.isoformat(timespec="seconds"),
        "task": "REHAB24-6 repetition correctness (1 correct, 0 incorrect)",
        "architecture": "1-D CNN over resampled joint angles and checks, with mask and exercise",
        "weights_sha256": weights_sha,
        "training_data": {
            "dataset": manifest["dataset"],
            "segmentation_sha256": manifest["segmentation_sha256"],
            "splits_sha256": manifest["splits_sha256"],
            "landmarks_sha256": manifest["landmarks_sha256"],
            "dataset_sha256": manifest.get("dataset_sha256"),
            "examples": manifest["examples"],
            "channels": manifest["channels"],
            "steps": manifest["steps"],
            "exercises": names,
        },
        "settings": settings,
        "chosen_epoch": best_epoch,
        "selection": "cross-validation over the training subjects"
        if final
        else "best epoch on the validation subjects",
        "cross_validation": cross_validation,
        "validation": val_metrics,
        "test": test_metrics,
        "target_agreement": TARGET_AGREEMENT,
        "meets_target_on_test": test_metrics["meets_target"],
        "code_commit": _git_commit(),
        "environment": {"python": platform.python_version(), "torch": torch.__version__},
        "licence_note": "Trained on REHAB24-6 (CC BY-NC 4.0): academic, non-commercial use only.",
    }
    text = json.dumps(record, indent=2) + "\n"
    (target / "record.json").write_text(text)
    if records_dir is not None:
        # The record (not the weights) is kept in the repository, so the team
        # can always see what each model was trained on and how it scored.
        records_dir.mkdir(parents=True, exist_ok=True)
        (records_dir / f"{version}.json").write_text(text)
    return target


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--records", type=Path, default=Path("model_records"))
    parser.add_argument("--epochs", type=int)
    parser.add_argument(
        "--from-crossval",
        type=Path,
        help="a rehab.crossval report: train its winning settings on the train and validation subjects",
    )
    args = parser.parse_args(argv)
    settings = {"epochs": args.epochs} if args.epochs else None
    cross_validation = None
    if args.from_crossval:
        report = json.loads(args.from_crossval.read_text())
        winner = report["winner"]
        settings = {**winner["settings"], "epochs": winner["epoch"] + 1, "fit_on_validation": True}
        cross_validation = {
            "report": args.from_crossval.name,
            "folds": report["folds"],
            "winner": winner["name"],
            "agreement": winner["agreement"],
            "balanced_accuracy": winner["balanced_accuracy"],
            "candidates": {name: c["best"] for name, c in report["candidates"].items()},
        }
    target = train(args.data, args.out, settings, args.records, cross_validation)
    record = json.loads((target / "record.json").read_text())
    test = record["test"]
    print(f"model {record['model_version']} (epoch {record['chosen_epoch']})")
    print(
        f"test agreement {test['agreement']:.1%}, balanced {test['balanced_accuracy']:.1%}, "
        f"always-'correct' baseline {test['majority_baseline_agreement']:.1%}, "
        f"target {record['target_agreement']:.0%}: {'met' if record['meets_target_on_test'] else 'NOT met'}"
    )
    for name, m in test["by_exercise"].items():
        if m["repetitions"]:
            print(f"  {name:14} {m['agreement']:.1%} of {m['repetitions']}")
    print(f"written to {target}")


if __name__ == "__main__":
    main()
