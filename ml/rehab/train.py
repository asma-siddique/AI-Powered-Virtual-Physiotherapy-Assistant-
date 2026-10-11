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


def train(
    data_path: Path, out_dir: Path, settings: dict | None = None, records_dir: Path | None = None
) -> Path:
    import torch  # noqa: PLC0415

    settings = {**SETTINGS, **(settings or {})}
    torch.manual_seed(settings["seed"])
    np.random.seed(settings["seed"])

    data = np.load(data_path)
    manifest = json.loads(data_path.with_suffix(".json").read_text())
    names = manifest["exercises"]
    split = data["split"]
    channels = data["x"].shape[1]

    def tensors(name: str):
        sel = split == name
        onehot = np.eye(len(names), dtype=np.float32)[data["exercise"][sel]]
        return (
            torch.from_numpy(data["x"][sel]),
            torch.from_numpy(data["mask"][sel]),
            torch.from_numpy(onehot),
            torch.from_numpy(data["label"][sel].astype(np.float32)),
            data["exercise"][sel],
        )

    train_x, train_m, train_e, train_y, _ = tensors("train")
    val = tensors("val")
    test = tensors("test")
    if min(len(train_y), len(val[3]), len(test[3])) == 0:
        raise SystemExit("every split needs examples; check the dataset manifest")

    model = _build_model(channels, len(names), settings["hidden"], settings["dropout"])
    optimizer = torch.optim.Adam(
        model.parameters(), lr=settings["learning_rate"], weight_decay=settings["weight_decay"]
    )
    # Incorrect repetitions are the rarer ones; they are weighted up so the
    # model cannot do well by calling everything correct.
    positives = float(train_y.sum())
    pos_weight = torch.tensor((len(train_y) - positives) / max(positives, 1.0))
    loss_fn = torch.nn.BCEWithLogitsLoss(pos_weight=pos_weight)

    def predict(x, m, e) -> np.ndarray:
        model.eval()
        with torch.no_grad():
            return (torch.sigmoid(model(x, m, e)) >= 0.5).long().numpy()

    best_state, best_score, best_epoch = None, -1.0, -1
    generator = torch.Generator().manual_seed(settings["seed"])
    for epoch in range(settings["epochs"]):
        model.train()
        order = torch.randperm(len(train_y), generator=generator)
        for start in range(0, len(order), settings["batch_size"]):
            idx = order[start : start + settings["batch_size"]]
            if len(idx) < 2:
                continue  # batch normalisation needs more than one example
            optimizer.zero_grad()
            loss = loss_fn(model(train_x[idx], train_m[idx], train_e[idx]), train_y[idx])
            loss.backward()
            optimizer.step()
        score = evaluate(val[3].numpy(), predict(*val[:3]), val[4], names)["balanced_accuracy"]
        if score > best_score:
            best_score, best_epoch = score, epoch
            best_state = {k: v.detach().clone() for k, v in model.state_dict().items()}

    model.load_state_dict(best_state)
    val_metrics = evaluate(val[3].numpy(), predict(*val[:3]), val[4], names)
    test_metrics = evaluate(test[3].numpy(), predict(*test[:3]), test[4], names)

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
    args = parser.parse_args(argv)
    target = train(args.data, args.out, {"epochs": args.epochs} if args.epochs else None, args.records)
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
